import Foundation
import WatchConnectivity

/// 发件箱 + 可靠同步：录好的分段先落盘到 outbox，再交给 WCSession 的文件队列。
/// 离线时系统会排队，连接恢复后自动送达；确认送达才删除本地文件，失败的会重新入队。
final class Sync: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = Sync()

    @Published var pending = 0
    @Published var capturePaused = false
    let outbox: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outbox = docs.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        super.init()
        refreshPending()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func sidecar(_ url: URL) -> URL { url.appendingPathExtension("json") }

    private func audioFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "m4a" }
    }

    func refreshPending() {
        let count = audioFiles().count
        DispatchQueue.main.async { self.pending = count }
    }

    /// 新分段入队。meta 同时写一份 sidecar，App 重启后还能补发。
    func enqueue(_ url: URL, meta: [String: Any]) {
        var plain: [String: Any] = meta
        if let d = meta[Wire.start] as? Date { plain[Wire.start] = d.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: plain) { try? data.write(to: sidecar(url)) }
        send(url)
        refreshPending()
    }

    private func send(_ url: URL) {
        guard WCSession.default.activationState == .activated else { return }
        guard let data = try? Data(contentsOf: sidecar(url)),
              var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let t = meta[Wire.start] as? Double { meta[Wire.start] = Date(timeIntervalSince1970: t) }
        WCSession.default.transferFile(url, metadata: meta)
    }

    /// 把 outbox 里还没在系统队列中的文件重新入队（重启后 / 失败后）。
    func resendMissing() {
        guard WCSession.default.activationState == .activated else { return }
        let queued = Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for url in audioFiles() where !queued.contains(url.lastPathComponent) { send(url) }
        refreshPending()
    }

    /// 删除某次录音：取消排队中的传输、删本地文件，并通知手机删除已收到的部分。
    func deleteSession(_ id: String) {
        for t in WCSession.default.outstandingFileTransfers where (t.file.metadata?[Wire.sessionID] as? String) == id {
            t.cancel()
        }
        for url in audioFiles() where url.lastPathComponent.hasPrefix(id + "_") {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sidecar(url))
        }
        if WCSession.default.activationState == .activated {
            WCSession.default.transferUserInfo([Wire.deleteSession: id])
        }
        refreshPending()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let paused = session.receivedApplicationContext[Wire.capturePaused] as? Bool ?? false
        DispatchQueue.main.async {
            self.capturePaused = paused
            self.resendMissing()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let paused = applicationContext[Wire.capturePaused] as? Bool ?? false
        DispatchQueue.main.async { self.capturePaused = paused }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        if error == nil {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sidecar(url))
            refreshPending()
        } else {
            // 保留文件，稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.resendMissing() }
        }
    }
}
