import Foundation
import UserNotifications
import WatchKit

/// 手表上的提醒（都带震动）：
/// - 晨间提醒：每天固定时间提醒开始记录，通知上可直接点「开始录音」。
/// - 中断提醒：录音被系统打断时立刻提醒，并在 3 / 10 分钟后再提醒，直到继续或结束。
/// - 看门狗：录音期间始终挂着一条 3 分钟后的提醒，每切一段就往后推；
///   如果 App 被系统终止（没机会推后），它就会响，告诉你录音可能断了。
/// - 暂停提醒：手动暂停 15 分钟后提醒一次。
/// 注意：系统不允许在后台自动开始/恢复录音，所以这些提醒都需要你点一下才会继续。
final class Nudges: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Nudges()
    private let center = UNUserNotificationCenter.current()

    func setup() {
        center.delegate = self
        let start = UNNotificationAction(identifier: "START", title: "开始录音", options: [.foreground])
        let resume = UNNotificationAction(identifier: "RESUME", title: "继续录音", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "morning", actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: "resume", actions: [resume], intentIdentifiers: []),
        ])
        scheduleMorning()
    }

    func requestAuth(_ done: (() -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { done?() }
        }
    }

    private func add(_ id: String, title: String, body: String, category: String, trigger: UNNotificationTrigger) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: 晨间

    func scheduleMorning() {
        center.removePendingNotificationRequests(withIdentifiers: ["morning"])
        let d = UserDefaults.standard
        guard d.bool(forKey: "morningEnabled") else { return }
        var comps = DateComponents()
        comps.hour = d.object(forKey: "morningHour") as? Int ?? 8
        comps.minute = d.object(forKey: "morningMinute") as? Int ?? 30
        add("morning", title: "开始今天的记录？", body: "点「开始录音」，拾言会震动确认。", category: "morning",
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true))
    }

    // MARK: 录音期间

    func armWatchdog() {
        add("watchdog", title: "录音可能已中断", body: "拾言没有在继续录音。点开继续。", category: "resume",
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 180, repeats: false))
        center.removePendingNotificationRequests(withIdentifiers: ["int1", "int2", "int3", "paused"])
    }

    func interrupted() {
        center.removePendingNotificationRequests(withIdentifiers: ["watchdog"])
        let delays: [(String, TimeInterval)] = [("int1", 2), ("int2", 180), ("int3", 600)]
        for (id, delay) in delays {
            add(id, title: "录音已中断", body: "已保存到中断前。点「继续录音」接着记。", category: "resume",
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        }
    }

    func paused() {
        center.removePendingNotificationRequests(withIdentifiers: ["watchdog", "int1", "int2", "int3"])
        add("paused", title: "录音仍在暂停", body: "已暂停 15 分钟。要继续记录吗？", category: "resume",
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 900, repeats: false))
    }

    func clearRuntime() {
        center.removePendingNotificationRequests(withIdentifiers: ["watchdog", "int1", "int2", "int3", "paused"])
        center.removeDeliveredNotifications(withIdentifiers: ["watchdog", "int1", "int2", "int3", "paused"])
    }

    // MARK: Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 录音正常进行时看门狗不该打扰；其余照常提示
        if notification.request.identifier == "watchdog", Recorder.shared.state == .recording {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        // 等 App 回到前台后再操作（系统要求录音从前台发起）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let recorder = Recorder.shared
            if category == "morning", action == "START" {
                recorder.start()
            } else if category == "resume" {
                if recorder.state == .paused { recorder.resume() } else if recorder.state == .idle { recorder.start() }
            }
        }
        completionHandler()
    }
}
