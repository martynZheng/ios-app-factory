import AVFoundation
import EventKit
import Foundation
import LocalAuthentication
import Security
import UserNotifications

// MARK: 钥匙串（云端密钥只存这里）

enum Keychain {
    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: 回听

final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Player()
    @Published var playingSegment: String?
    private var player: AVAudioPlayer?

    func toggle(segmentID: String, at offset: Double) {
        if playingSegment == segmentID { stop(); return }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: Store.shared.audioURL(segmentID))
            p.delegate = self
            p.currentTime = max(0, offset - 0.5)
            p.play()
            player = p
            playingSegment = segmentID
        } catch {
            playingSegment = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingSegment = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}

// MARK: 每日摘要通知

enum Notifier {
    /// 按设置重排每日通知。正文在排程时确定：默认不含任何对话内容。
    static func apply() {
        let d = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily"])
        guard d.bool(forKey: "notifyEnabled") else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "今日回顾"
            var body = "今天的对话回顾已准备好，点开查看。"
            if d.bool(forKey: "notifyPreview") {
                let todos = Store.shared.db.digests[Store.dayKey(Date())]?.items.filter { $0.kind == .todo && !$0.done } ?? []
                if let first = todos.first { body = "今日 \(todos.count) 条待办：\(first.text)" }
            }
            content.body = body
            content.sound = .default
            var comps = DateComponents()
            comps.hour = d.object(forKey: "notifyHour") as? Int ?? 21
            comps.minute = d.object(forKey: "notifyMinute") as? Int ?? 30
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            center.add(UNNotificationRequest(identifier: "daily", content: content, trigger: trigger))
        }
    }
}

// MARK: 提醒事项 / 日历（仅在用户逐条确认后调用）

enum Exporter {
    private static let store = EKEventStore()

    static func addReminder(_ item: DigestItem, source: String) async -> String {
        do {
            guard try await store.requestFullAccessToReminders() else { return "没有提醒事项权限" }
            guard let calendar = store.defaultCalendarForNewReminders() else { return "没有可用的提醒事项列表" }
            let reminder = EKReminder(eventStore: store)
            reminder.title = item.text
            reminder.notes = "来自拾言：\(source)"
            reminder.calendar = calendar
            if let due = item.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
            }
            try store.save(reminder, commit: true)
            return "已写入提醒事项"
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }

    static func addEvent(_ item: DigestItem, source: String) async -> String {
        guard let due = item.dueDate else { return "这条待办没有明确日期" }
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return "没有日历权限" }
            guard let calendar = store.defaultCalendarForNewEvents else { return "没有可用的日历" }
            let event = EKEvent(eventStore: store)
            event.title = item.text
            event.notes = "来自拾言：\(source)"
            event.startDate = due
            event.endDate = due
            event.isAllDay = true
            event.calendar = calendar
            try store.save(event, span: .thisEvent, commit: true)
            return "已写入日历"
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: App 锁

enum AppLock {
    static func unlock(_ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { done(true); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁拾言") { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}
