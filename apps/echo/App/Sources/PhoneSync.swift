import Foundation
import WatchConnectivity

/// 接收手表传来的录音分段。
final class PhoneSync: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneSync()

    @Published var watchStatus = "未连接"

    func activate() {
        guard WCSession.isSupported() else { watchStatus = "此设备不支持 Apple Watch"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 把「暂停采集」同步给手表（手表端会禁用开始按钮）。
    func pushCapturePaused(_ paused: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([Wire.capturePaused: paused])
    }

    private func refreshStatus(_ session: WCSession) {
        let text: String
        if !session.isPaired { text = "未配对 Apple Watch" }
        else if !session.isWatchAppInstalled { text = "手表上尚未安装拾言" }
        else { text = session.isReachable ? "手表已连接" : "手表 App 已安装（当前未在前台）" }
        DispatchQueue.main.async { self.watchStatus = text }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        refreshStatus(session)
        DispatchQueue.main.async {
            self.pushCapturePaused(UserDefaults.standard.bool(forKey: "capturePaused"))
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    func sessionReachabilityDidChange(_ session: WCSession) { refreshStatus(session) }
    func sessionWatchStateDidChange(_ session: WCSession) { refreshStatus(session) }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 必须在返回前把文件移走（系统随后会删除临时文件）
        let meta = file.metadata ?? [:]
        guard let sid = meta[Wire.sessionID] as? String else { return }
        let index = meta[Wire.index] as? Int ?? 0
        let start = meta[Wire.start] as? Date ?? Date()
        let duration = meta[Wire.duration] as? Double ?? 0
        let id = "\(sid)_\(index)"
        let dest = Store.shared.audioURL(id)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: file.fileURL, to: dest)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
        } catch { return }
        DispatchQueue.main.async {
            if Store.shared.db.deletedSessions.contains(sid) {
                try? FileManager.default.removeItem(at: dest)
                return
            }
            Store.shared.addSegment(Segment(id: id, sessionID: sid, index: index, start: start, duration: duration,
                                            hasAudio: true, status: .pending, error: nil))
            Transcriber.shared.kick()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let sid = userInfo[Wire.deleteSession] as? String else { return }
        DispatchQueue.main.async { Store.shared.deleteSession(sid, tombstone: true) }
    }
}
