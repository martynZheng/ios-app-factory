import Foundation
import EventKit
import HealthKit
import Contacts
import UIKit

// MARK: - 手机里的应用
//
// 官方应用：健康（HealthKit，只读）、日历和提醒事项（EventKit，读写）、通讯录（Contacts，只读）。第一次用到时系统会弹授权。
// 其他应用：iOS 不允许一个 App 读别的 App 的数据。能做的是——
//   1. 运行你的“快捷指令”（快捷指令能调用很多第三方 App 的动作，结果会传回来）；
//   2. 用链接打开某个 App 或页面（地图导航、微信、网页……）；
//   3. 有开放接口的服务，用连接器（MCP）接入。

@MainActor
final class PhoneApps {
    static let shared = PhoneApps()
    let events = EKEventStore()
    let health = HKHealthStore()
    let contacts = CNContactStore()
    static let callbackScheme = "shiyan-echo"

    private let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f
    }()

    static func parse(_ any: Any?) -> Date? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let full = DateFormatter()
        full.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = full.date(from: s) { return d }
        let dayOnly = DateFormatter()
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: s)
    }

    // MARK: 授权

    func calendarAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await events.requestFullAccessToEvents()) ?? false
    }

    func remindersAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        return (try? await events.requestFullAccessToReminders()) ?? false
    }

    func contactsAccess() async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return (try? await contacts.requestAccess(for: .contacts)) ?? false
    }

    static var healthTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = [HKObjectType.workoutType()]
        let ids: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .distanceWalkingRunning, .restingHeartRate,
                                               .heartRate, .heartRateVariabilitySDNN, .bodyMass, .appleExerciseTime, .flightsClimbed]
        for id in ids { set.insert(HKQuantityType(id)) }
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKCategoryType(.mindfulSession))
        return set
    }

    /// 健康数据：系统不会告诉 App 你拒绝了哪一项（拒绝的项读出来是空的）。
    func healthAccess() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else { return "这台设备不支持“健康”。" }
        do {
            try await health.requestAuthorization(toShare: [], read: Self.healthTypes)
            return nil
        } catch {
            return "没拿到“健康”的授权：\(error.localizedDescription)"
        }
    }

    // MARK: 健康

    private func statistics(_ id: HKQuantityTypeIdentifier, unit: HKUnit, sum: Bool, from: Date, to: Date) async -> [(Date, Double)] {
        let type = HKQuantityType(id)
        let store = health
        let start = Calendar.current.startOfDay(for: from)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: to)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: sum ? .cumulativeSum : .discreteAverage,
                                                    anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, _ in
                var out: [(Date, Double)] = []
                collection?.enumerateStatistics(from: start, to: to) { stats, _ in
                    let q = sum ? stats.sumQuantity() : stats.averageQuantity()
                    if let q { out.append((stats.startDate, q.doubleValue(for: unit))) }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    private func samples(_ type: HKSampleType, from: Date, to: Date, limit: Int = HKObjectQueryNoLimit) async -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let store = health
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            store.execute(query)
        }
    }

    func healthReport(metric: String, days: Int) async -> String {
        if let problem = await healthAccess() { return problem }
        let days = max(1, min(days, 90))
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: to)) ?? to
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        func daily(_ rows: [(Date, Double)], _ unit: String, _ digits: Int) -> String {
            guard !rows.isEmpty else { return "这段时间没有数据（可能没授权这一项，或设备没记录）。" }
            let fmt = "%.\(digits)f"
            let lines = rows.map { "\(day.string(from: $0.0))：\(String(format: fmt, $0.1)) \(unit)" }
            let avg = rows.map { $0.1 }.reduce(0, +) / Double(rows.count)
            return lines.joined(separator: "\n") + "\n平均：\(String(format: fmt, avg)) \(unit)"
        }
        switch metric {
        case "steps":
            return "步数\n" + daily(await statistics(.stepCount, unit: .count(), sum: true, from: from, to: to), "步", 0)
        case "active_energy":
            return "活动消耗\n" + daily(await statistics(.activeEnergyBurned, unit: .kilocalorie(), sum: true, from: from, to: to), "千卡", 0)
        case "distance":
            return "步行跑步距离\n" + daily(await statistics(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), sum: true, from: from, to: to), "公里", 2)
        case "exercise_minutes":
            return "锻炼分钟\n" + daily(await statistics(.appleExerciseTime, unit: .minute(), sum: true, from: from, to: to), "分钟", 0)
        case "resting_heart_rate":
            return "静息心率\n" + daily(await statistics(.restingHeartRate, unit: perMinute, sum: false, from: from, to: to), "次/分", 0)
        case "heart_rate":
            return "平均心率\n" + daily(await statistics(.heartRate, unit: perMinute, sum: false, from: from, to: to), "次/分", 0)
        case "hrv":
            return "心率变异性\n" + daily(await statistics(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), sum: false, from: from, to: to), "毫秒", 0)
        case "weight":
            let list = await samples(HKQuantityType(.bodyMass), from: from, to: to, limit: 30).compactMap { $0 as? HKQuantitySample }
            guard !list.isEmpty else { return "这段时间没有体重记录。" }
            return "体重\n" + list.map { "\(stamp.string(from: $0.startDate))：\(String(format: "%.1f", $0.quantity.doubleValue(for: .gramUnit(with: .kilo)))) 公斤" }.joined(separator: "\n")
        case "sleep":
            return await sleepReport(from: from.addingTimeInterval(-12 * 3600), to: to)
        case "workouts":
            let list = await samples(HKObjectType.workoutType(), from: from, to: to, limit: 50).compactMap { $0 as? HKWorkout }
            guard !list.isEmpty else { return "这段时间没有体能训练记录。" }
            return "体能训练\n" + list.map { w in
                var row = "\(stamp.string(from: w.startDate)) \(Self.workoutName(w.workoutActivityType))，\(Int(w.duration / 60)) 分钟"
                if let d = w.totalDistance { row += "，\(String(format: "%.2f", d.doubleValue(for: .meterUnit(with: .kilo)))) 公里" }
                if let e = w.totalEnergyBurned { row += "，\(Int(e.doubleValue(for: .kilocalorie()))) 千卡" }
                return row
            }.joined(separator: "\n")
        case "mindful":
            let list = await samples(HKCategoryType(.mindfulSession), from: from, to: to)
            guard !list.isEmpty else { return "这段时间没有正念记录。" }
            let minutes = list.map { $0.endDate.timeIntervalSince($0.startDate) / 60 }.reduce(0, +)
            return "正念：\(list.count) 次，共 \(Int(minutes)) 分钟"
        default:
            return "不认识的指标 \(metric)。"
        }
    }

    private func sleepReport(from: Date, to: Date) async -> String {
        let list = await samples(HKCategoryType(.sleepAnalysis), from: from, to: to).compactMap { $0 as? HKCategorySample }
        guard !list.isEmpty else { return "这段时间没有睡眠数据（需要戴手表睡觉，或在“健康”里设置睡眠）。" }
        // 按醒来的那天归到“哪一晚”
        var nights: [String: (asleep: Double, deep: Double, rem: Double, bed: Date, wake: Date)] = [:]
        let key = DateFormatter()
        key.dateFormat = "yyyy-MM-dd"
        for s in list {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: s.value), value != .inBed, value != .awake else { continue }
            let k = key.string(from: s.endDate)
            let length = s.endDate.timeIntervalSince(s.startDate) / 3600
            var n = nights[k] ?? (0, 0, 0, s.startDate, s.endDate)
            n.asleep += length
            if value == .asleepDeep { n.deep += length }
            if value == .asleepREM { n.rem += length }
            n.bed = min(n.bed, s.startDate)
            n.wake = max(n.wake, s.endDate)
            nights[k] = n
        }
        guard !nights.isEmpty else { return "这段时间只有卧床记录，没有睡着的数据。" }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let rows = nights.keys.sorted().map { k -> String in
            let n = nights[k]!
            var row = "\(day.string(from: n.wake))：睡了 \(String(format: "%.1f", n.asleep)) 小时（\(hm.string(from: n.bed))–\(hm.string(from: n.wake))）"
            if n.deep > 0 || n.rem > 0 { row += "，深睡 \(String(format: "%.1f", n.deep))，快速眼动 \(String(format: "%.1f", n.rem))" }
            return row
        }
        return "睡眠\n" + rows.joined(separator: "\n")
    }

    static func workoutName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .highIntensityIntervalTraining: return "高强度间歇"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .tennis: return "网球"
        case .tableTennis: return "乒乓球"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .dance, .socialDance, .cardioDance: return "跳舞"
        default: return "运动"
        }
    }

    // MARK: 日历

    func listEvents(from: Date, to: Date, query: String?) async -> String {
        guard await calendarAccess() else { return "没有日历权限。到系统「设置 › 拾言 › 日历」改成“完全访问”。" }
        let predicate = events.predicateForEvents(withStart: from, end: to, calendars: nil)
        var list = events.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            list = list.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) || ($0.location ?? "").localizedCaseInsensitiveContains(q) || ($0.notes ?? "").localizedCaseInsensitiveContains(q) }
        }
        guard !list.isEmpty else { return "这段时间没有日程。" }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        return list.prefix(60).map { e in
            var row = e.isAllDay ? "\(day.string(from: e.startDate)) 全天 \(e.title ?? "")" : "\(stamp.string(from: e.startDate))–\(hm.string(from: e.endDate)) \(e.title ?? "")"
            if let loc = e.location, !loc.isEmpty { row += "（\(loc)）" }
            row += " ［\(e.calendar.title)］ id=\(e.eventIdentifier ?? "")"
            return row
        }.joined(separator: "\n")
    }

    func createEvent(title: String, start: Date, end: Date?, location: String?, notes: String?, alarmMinutes: Int?) async -> String {
        guard await calendarAccess() else { return "没有日历权限。" }
        guard let calendar = events.defaultCalendarForNewEvents else { return "没有可写的日历。" }
        let e = EKEvent(eventStore: events)
        e.title = title
        e.startDate = start
        e.endDate = max(end ?? start.addingTimeInterval(3600), start)
        e.location = location
        e.notes = notes
        e.calendar = calendar
        if let m = alarmMinutes { e.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * m))) }
        do {
            try events.save(e, span: .thisEvent, commit: true)
            return "已写入日历：\(stamp.string(from: start)) \(title)。id=\(e.eventIdentifier ?? "")"
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }

    func updateEvent(id: String, title: String?, start: Date?, end: Date?, location: String?, notes: String?) async -> String {
        guard await calendarAccess() else { return "没有日历权限。" }
        guard let e = events.event(withIdentifier: id) else { return "找不到这个日程（id 可能变了，先用 calendar_events 重新查）。" }
        let length = e.endDate.timeIntervalSince(e.startDate)
        if let title, !title.isEmpty { e.title = title }
        if let start {
            e.startDate = start
            e.endDate = end ?? start.addingTimeInterval(length)
        } else if let end {
            e.endDate = end
        }
        if let location { e.location = location }
        if let notes { e.notes = notes }
        do {
            try events.save(e, span: .thisEvent, commit: true)
            return "已更新：\(stamp.string(from: e.startDate)) \(e.title ?? "")"
        } catch {
            return "更新失败：\(error.localizedDescription)"
        }
    }

    func deleteEvent(id: String) -> String {
        guard let e = events.event(withIdentifier: id) else { return "找不到这个日程。" }
        do {
            try events.remove(e, span: .thisEvent, commit: true)
            return "已删除日程"
        } catch {
            return "删除失败：\(error.localizedDescription)"
        }
    }

    func eventTitle(_ id: String) -> (String, Date?)? {
        guard let e = events.event(withIdentifier: id) else { return nil }
        return (e.title ?? "", e.startDate)
    }

    // MARK: 提醒事项

    private func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
        let store = events
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { list in continuation.resume(returning: list ?? []) }
        }
    }

    func listReminders(list name: String?, completed: Bool) async -> String {
        guard await remindersAccess() else { return "没有提醒事项权限。到系统「设置 › 拾言 › 提醒事项」改成“完全访问”。" }
        var calendars = events.calendars(for: .reminder)
        if let name, !name.isEmpty { calendars = calendars.filter { $0.title.localizedCaseInsensitiveContains(name) } }
        guard !calendars.isEmpty else { return "没有叫「\(name ?? "")」的列表。现有列表：\(events.calendars(for: .reminder).map { $0.title }.joined(separator: "、"))" }
        let predicate = completed
            ? events.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-14 * 86_400), ending: Date(), calendars: calendars)
            : events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let list = await fetchReminders(predicate)
        guard !list.isEmpty else { return completed ? "最近两周没有完成的提醒。" : "没有未完成的提醒。" }
        let sorted = list.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        return "列表：\(calendars.map { $0.title }.joined(separator: "、"))\n" + sorted.prefix(80).map { r in
            var row = "- \(r.title ?? "")"
            if let due = r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { row += "（\(stamp.string(from: due))）" }
            if r.priority > 0 && r.priority <= 4 { row += "［重要］" }
            row += " ［\(r.calendar.title)］ id=\(r.calendarItemIdentifier)"
            return row
        }.joined(separator: "\n")
    }

    func createReminder(title: String, due: Date?, notes: String?, list name: String?) async -> String {
        guard await remindersAccess() else { return "没有提醒事项权限。" }
        var calendar = events.defaultCalendarForNewReminders()
        if let name, !name.isEmpty, let match = events.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveContains(name) }) {
            calendar = match
        }
        guard let calendar else { return "没有可用的提醒事项列表。" }
        let r = EKReminder(eventStore: events)
        r.title = title
        r.notes = notes
        r.calendar = calendar
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try events.save(r, commit: true)
            return "已加到「\(calendar.title)」：\(title)\(due.map { "（\(stamp.string(from: $0))）" } ?? "")。id=\(r.calendarItemIdentifier)"
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }

    func completeReminder(id: String, done: Bool) async -> String {
        guard await remindersAccess() else { return "没有提醒事项权限。" }
        guard let r = events.calendarItem(withIdentifier: id) as? EKReminder else { return "找不到这条提醒（先用 reminders_list 重新查）。" }
        r.isCompleted = done
        do {
            try events.save(r, commit: true)
            return done ? "已勾掉：\(r.title ?? "")" : "已恢复为未完成：\(r.title ?? "")"
        } catch {
            return "操作失败：\(error.localizedDescription)"
        }
    }

    func deleteReminder(id: String) -> String {
        guard let r = events.calendarItem(withIdentifier: id) as? EKReminder else { return "找不到这条提醒。" }
        do {
            try events.remove(r, commit: true)
            return "已删除提醒"
        } catch {
            return "删除失败：\(error.localizedDescription)"
        }
    }

    func reminderTitle(_ id: String) -> String? {
        (events.calendarItem(withIdentifier: id) as? EKReminder)?.title
    }

    // MARK: 通讯录

    func searchContacts(_ query: String) async -> String {
        guard await contactsAccess() else { return "没有通讯录权限。到系统「设置 › 拾言 › 通讯录」打开。" }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey,
                                       CNContactPostalAddressesKey].map { $0 as CNKeyDescriptor }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "要给一个名字。" }
        var found = (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys)) ?? []
        if found.isEmpty, q.count >= 2 {
            // 名字里搜不到，再按公司、昵称找
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? contacts.enumerateContacts(with: request) { c, stop in
                if c.organizationName.localizedCaseInsensitiveContains(q) || c.nickname.localizedCaseInsensitiveContains(q) {
                    found.append(c)
                    if found.count >= 20 { stop.pointee = true }
                }
            }
        }
        guard !found.isEmpty else { return "通讯录里没有「\(q)」。" }
        return found.prefix(20).map { c in
            var row = "\(c.familyName)\(c.givenName)"
            if !c.nickname.isEmpty { row += "（\(c.nickname)）" }
            let work = [c.organizationName, c.jobTitle].filter { !$0.isEmpty }.joined(separator: " ")
            if !work.isEmpty { row += "，\(work)" }
            let phones = c.phoneNumbers.map { $0.value.stringValue }
            if !phones.isEmpty { row += "，电话 \(phones.joined(separator: " / "))" }
            let mails = c.emailAddresses.map { $0.value as String }
            if !mails.isEmpty { row += "，邮箱 \(mails.joined(separator: " / "))" }
            if let b = c.birthday, let m = b.month, let d = b.day { row += "，生日 \(m)月\(d)日" }
            if let addr = c.postalAddresses.first?.value {
                let text = [addr.city, addr.street].filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty { row += "，地址 \(text)" }
            }
            return row
        }.joined(separator: "\n")
    }

    // MARK: 快捷指令与其他应用

    static var shortcutList: String { UserDefaults.standard.string(forKey: "myShortcuts") ?? "" }

    fileprivate var pending: [String: CheckedContinuation<String, Never>] = [:]

    /// 运行一个快捷指令，把输入的文字交给它，等它把结果传回来（会短暂切到“快捷指令”App 再回来）。
    func runShortcut(name: String, input: String?) async -> String {
        let token = UUID().uuidString
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "x-callback-url"
        parts.path = "/run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input, !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        items.append(URLQueryItem(name: "x-success", value: "\(Self.callbackScheme)://shortcut?token=\(token)&status=ok"))
        items.append(URLQueryItem(name: "x-cancel", value: "\(Self.callbackScheme)://shortcut?token=\(token)&status=cancel"))
        items.append(URLQueryItem(name: "x-error", value: "\(Self.callbackScheme)://shortcut?token=\(token)&status=error"))
        parts.queryItems = items
        guard let url = parts.url else { return "快捷指令名字不合法。" }
        let opened = await UIApplication.shared.open(url)
        guard opened else { return "打不开“快捷指令”App。" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            if let c = PhoneApps.shared.pending.removeValue(forKey: token) {
                c.resume(returning: "快捷指令已经启动，但两分钟内没有回传结果（可能还在运行，或它没有输出）。")
            }
        }
        return await withCheckedContinuation { continuation in
            pending[token] = continuation
        }
    }

    /// 处理快捷指令跑完后的回调 shiyan-echo://shortcut?token=…&status=…&result=…
    func handle(_ url: URL) {
        guard url.scheme == Self.callbackScheme, url.host == "shortcut",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let c = pending.removeValue(forKey: token) else { return }
        let status = items.first(where: { $0.name == "status" })?.value ?? ""
        let result = items.first(where: { $0.name == "result" })?.value ?? ""
        let message = items.first(where: { $0.name == "errorMessage" })?.value ?? ""
        switch status {
        case "ok": c.resume(returning: result.isEmpty ? "快捷指令运行完了（没有输出内容）。" : "快捷指令的结果：\n\(String(result.prefix(8000)))")
        case "cancel": c.resume(returning: "快捷指令被取消了。")
        default: c.resume(returning: "快捷指令出错了：\(message.isEmpty ? "没有说明" : message)。可能是名字不对。")
        }
    }

    func open(_ text: String) async -> String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return "链接不合法。" }
        guard scheme != Self.callbackScheme else { return "不能打开这个链接。" }
        let ok = await UIApplication.shared.open(url)
        return ok ? "已打开。" : "打不开（这台手机上可能没装对应的 App）。"
    }
}

// MARK: - 给智能体的工具

enum PhoneTools {
    private static let str: [String: Any] = ["type": "string"]
    private static let int: [String: Any] = ["type": "integer"]
    private static let bool: [String: Any] = ["type": "boolean"]
    private static func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    /// 只读的：健康、日历、提醒事项、通讯录。对话和主动提醒都能用。
    @MainActor
    static func read() -> [AgentTool] {
        let apps = PhoneApps.shared
        let metric: [String: Any] = ["type": "string", "enum": ["steps", "sleep", "workouts", "active_energy", "exercise_minutes", "distance",
                                                                 "resting_heart_rate", "heart_rate", "hrv", "weight", "mindful"]]
        return [
            AgentTool(name: "health_data", description: """
                读“健康”App 里的数据（来自 iPhone 和 Apple Watch）：steps 步数、sleep 睡眠、workouts 体能训练、active_energy 活动消耗、exercise_minutes 锻炼分钟、
                distance 步行跑步距离、resting_heart_rate 静息心率、heart_rate 心率、hrv 心率变异性、weight 体重、mindful 正念。days 是最近几天（1–90，默认 7）。
                """, parameters: obj(["metric": metric, "days": int], ["metric"])) { args in
                let days = (args["days"] as? Int) ?? Int("\(args["days"] ?? "")") ?? 7
                return ToolResult(content: await apps.healthReport(metric: args["metric"] as? String ?? "", days: days))
            },
            AgentTool(name: "calendar_events", description: "查“日历”里的日程（所有日历）。时间 yyyy-MM-dd 或 yyyy-MM-dd HH:mm；query 可选，按标题/地点/备注过滤。返回里带 id，改日程时用。",
                      parameters: obj(["from": str, "to": str, "query": str], ["from", "to"])) { args in
                let from = PhoneApps.parse(args["from"]) ?? Calendar.current.startOfDay(for: Date())
                var to = PhoneApps.parse(args["to"]) ?? from.addingTimeInterval(86_400)
                if to <= from { to = from.addingTimeInterval(86_400) }
                if (args["to"] as? String)?.count == 10 { to = to.addingTimeInterval(86_399) }
                return ToolResult(content: await apps.listEvents(from: from, to: to, query: args["query"] as? String))
            },
            AgentTool(name: "reminders_list", description: "查“提醒事项”App 里的提醒。list 可选（列表名）；completed=true 看最近两周完成的。返回里带 id。",
                      parameters: obj(["list": str, "completed": bool], [])) { args in
                ToolResult(content: await apps.listReminders(list: args["list"] as? String, completed: args["completed"] as? Bool ?? false))
            },
            AgentTool(name: "contacts_search", description: "在通讯录里按名字（或公司、昵称）查人：电话、邮箱、生日、公司、地址。",
                      parameters: obj(["name": str], ["name"])) { args in
                ToolResult(content: await apps.searchContacts(args["name"] as? String ?? ""))
            },
        ]
    }

    /// 会改东西的：只在对话里给（你在场）。删除要你点确认。
    @MainActor
    static func act(proposeDelete: @escaping (Proposal) -> Void) -> [AgentTool] {
        let apps = PhoneApps.shared
        var tools: [AgentTool] = [
            AgentTool(name: "calendar_create", description: "在“日历”里直接新建日程。start/end 格式 yyyy-MM-dd HH:mm（end 不填默认 1 小时）；alarm_minutes 提前几分钟提醒，可选。",
                      parameters: obj(["title": str, "start": str, "end": str, "location": str, "notes": str, "alarm_minutes": int], ["title", "start"])) { args in
                guard let start = PhoneApps.parse(args["start"]) else { return ToolResult(content: "start 格式应为 yyyy-MM-dd HH:mm。", isError: true) }
                let result = await apps.createEvent(title: args["title"] as? String ?? "", start: start, end: PhoneApps.parse(args["end"]),
                                                    location: args["location"] as? String, notes: args["notes"] as? String, alarmMinutes: args["alarm_minutes"] as? Int)
                return ToolResult(content: result)
            },
            AgentTool(name: "calendar_update", description: "修改一个日程（id 来自 calendar_events）。只传要改的字段；改了 start 不传 end 会保持原时长。",
                      parameters: obj(["id": str, "title": str, "start": str, "end": str, "location": str, "notes": str], ["id"])) { args in
                ToolResult(content: await apps.updateEvent(id: args["id"] as? String ?? "", title: args["title"] as? String, start: PhoneApps.parse(args["start"]),
                                                           end: PhoneApps.parse(args["end"]), location: args["location"] as? String, notes: args["notes"] as? String))
            },
            AgentTool(name: "reminders_create", description: "在“提醒事项”里直接新建一条。due 可选（yyyy-MM-dd HH:mm，到点会响）；list 可选（列表名，不填用默认列表）。",
                      parameters: obj(["title": str, "due": str, "notes": str, "list": str], ["title"])) { args in
                ToolResult(content: await apps.createReminder(title: args["title"] as? String ?? "", due: PhoneApps.parse(args["due"]),
                                                              notes: args["notes"] as? String, list: args["list"] as? String))
            },
            AgentTool(name: "reminders_complete", description: "勾掉一条提醒（id 来自 reminders_list）；done=false 是取消勾选。",
                      parameters: obj(["id": str, "done": bool], ["id"])) { args in
                ToolResult(content: await apps.completeReminder(id: args["id"] as? String ?? "", done: args["done"] as? Bool ?? true))
            },
            AgentTool(name: "delete_item", description: "删除一个日程或一条提醒（kind: event / reminder，id 来自查询结果）。会在界面上放一张卡片等我点确认，你不能替我确认。",
                      parameters: obj(["kind": ["type": "string", "enum": ["event", "reminder"]] as [String: Any], "id": str], ["kind", "id"])) { args in
                let id = args["id"] as? String ?? ""
                let isEvent = (args["kind"] as? String) == "event"
                let found: (String, Date?)? = await MainActor.run { () -> (String, Date?)? in
                    if isEvent { return apps.eventTitle(id) }
                    if let title = apps.reminderTitle(id) { return (title, nil) }
                    return nil
                }
                guard let found else { return ToolResult(content: "找不到这个\(isEvent ? "日程" : "提醒")，先重新查一下 id。", isError: true) }
                var p = Proposal(kind: isEvent ? .deleteEvent : .deleteReminder, title: found.0, notes: nil, start: found.1)
                p.targetID = id
                await MainActor.run { proposeDelete(p) }
                return ToolResult(content: "删除卡片已经放到界面上，等我点确认。告诉我点一下就行，不要说已经删了。")
            },
            AgentTool(name: "open_url", description: """
                在手机上打开一个链接或 App：网页（https://…）、地图导航（如 https://maps.apple.com/?daddr=目的地&dirflg=d，或 iosamap://、baidumap:// ）、
                打电话（tel:号码，系统会先问我）、发短信（sms:号码）、发邮件（mailto:）、其他 App（如 weixin://、alipay://、music://）。
                """, parameters: obj(["url": str], ["url"])) { args in
                ToolResult(content: await apps.open(args["url"] as? String ?? ""))
            },
        ]
        let shortcuts = PhoneApps.shortcutList.trimmingCharacters(in: .whitespacesAndNewlines)
        tools.append(AgentTool(name: "run_shortcut", description: """
            运行我手机上的一个“快捷指令”，可以把一段文字作为输入传给它，它的输出会传回来（会短暂切到“快捷指令”App 再切回来）。
            很多第三方 App（记账、笔记、智能家居、打车……）都把动作开放给了快捷指令，这是操作其他 App 的主要办法。name 必须和快捷指令的名字完全一样。
            """ + (shortcuts.isEmpty ? "我还没告诉你有哪些快捷指令；不确定名字就先问我。" : "我登记过的快捷指令：\n" + shortcuts),
            parameters: obj(["name": str, "input": str], ["name"])) { args in
            ToolResult(content: await apps.runShortcut(name: args["name"] as? String ?? "", input: args["input"] as? String))
        })
        return tools
    }
}
