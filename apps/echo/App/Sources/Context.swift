import Foundation
import CoreLocation
import CoreMotion
import EventKit

// MARK: - 情境：你在哪、在干什么、日程上写着什么

/// 身体状态，来自 iPhone 的运动协处理器（系统自动记录最近 7 天，不需要 App 常驻）。
enum Activity: String, Codable {
    case still, walking, running, cycling, driving, unknown

    var label: String {
        switch self {
        case .still: return "静止"
        case .walking: return "步行"
        case .running: return "跑步"
        case .cycling: return "骑行"
        case .driving: return "乘车"
        case .unknown: return ""
        }
    }

    var symbol: String {
        switch self {
        case .still: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car"
        case .unknown: return "questionmark"
        }
    }
}

/// 一次到访：系统的“到访”检测（到了某处、离开某处）或一次显著位置变化。
struct PlaceVisit: Codable, Identifiable {
    var id: UUID
    var arrive: Date
    var depart: Date?
    var lat: Double
    var lon: Double
    var name: String?
}

/// 时间线上的一小段情境。
struct ContextSpan: Equatable {
    var start: Date
    var end: Date
    var activity: Activity
    var place: String?
    var event: String?
}

/// 情境感知。全部数据只存在本机；只有你开启了云端智能体时，地点名称和状态（不含坐标）才会随转写一起发给它。
final class ContextSensor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = ContextSensor()

    @Published private(set) var visits: [PlaceVisit] = []
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let events = EKEventStore()
    private let geocoder = CLGeocoder()
    private var geocoding = false
    private let fileURL: URL

    static var locationOn: Bool { UserDefaults.standard.bool(forKey: "senseLocation") }
    static var motionOn: Bool { UserDefaults.standard.bool(forKey: "senseMotion") }
    static var calendarOn: Bool { UserDefaults.standard.bool(forKey: "senseCalendar") }

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        fileURL = base.appendingPathComponent("places.json")
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationStatus = location.authorizationStatus
        if !Store.isDemo, let data = try? Data(contentsOf: fileURL), let loaded = try? JSONDecoder().decode([PlaceVisit].self, from: data) {
            visits = loaded
        }
    }

    // MARK: 开关

    func start() {
        guard !Store.isDemo else { return }
        if Self.locationOn { beginLocation() }
        nameMissingPlaces()
    }

    func enableLocation(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "senseLocation")
        if on {
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            } else {
                location.requestAlwaysAuthorization()
                beginLocation()
            }
        } else {
            location.stopMonitoringVisits()
            location.stopMonitoringSignificantLocationChanges()
        }
    }

    func enableMotion(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "senseMotion")
        guard on, CMMotionActivityManager.isActivityAvailable() else { return }
        // 第一次查询会触发系统授权弹窗
        let now = Date()
        motion.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in }
    }

    func enableCalendar(_ on: Bool) async -> Bool {
        UserDefaults.standard.set(on, forKey: "senseCalendar")
        guard on else { return false }
        let granted = (try? await events.requestFullAccessToEvents()) ?? false
        if !granted { UserDefaults.standard.set(false, forKey: "senseCalendar") }
        return granted
    }

    private func beginLocation() {
        let status = location.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        location.startMonitoringVisits()
        location.startMonitoringSignificantLocationChanges()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
        guard Self.locationOn else { return }
        if manager.authorizationStatus == .authorizedWhenInUse {
            // 后台的到访检测需要“始终”权限；系统会在合适的时候再问一次
            manager.requestAlwaysAuthorization()
        }
        beginLocation()
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrive = visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate
        let depart = visit.departureDate == .distantFuture ? nil : visit.departureDate
        DispatchQueue.main.async {
            // 同一地点的到达/离开是两次回调：合并
            if let i = self.visits.lastIndex(where: { abs($0.arrive.timeIntervalSince(arrive)) < 120 && self.near($0, visit.coordinate) }) {
                self.visits[i].depart = depart
            } else {
                self.visits.append(PlaceVisit(id: UUID(), arrive: arrive, depart: depart,
                                              lat: visit.coordinate.latitude, lon: visit.coordinate.longitude, name: nil))
            }
            self.save()
            self.nameMissingPlaces()
            if depart == nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)   // 等地名解析出来
                    await Proactive.shared.consider(reason: "刚到一个新地点")
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 1000 else { return }
        DispatchQueue.main.async {
            if let last = self.visits.last, self.near(last, fix.coordinate), last.depart == nil { return }
            if let i = self.visits.indices.last, self.visits[i].depart == nil, self.visits[i].arrive < fix.timestamp {
                self.visits[i].depart = fix.timestamp
            }
            self.visits.append(PlaceVisit(id: UUID(), arrive: fix.timestamp, depart: nil,
                                          lat: fix.coordinate.latitude, lon: fix.coordinate.longitude, name: nil))
            self.save()
            self.nameMissingPlaces()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func near(_ v: PlaceVisit, _ c: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: v.lat, longitude: v.lon).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 250
    }

    /// 逐个把坐标翻译成地名（系统地理编码有频率限制，一次一个）。
    private func nameMissingPlaces() {
        guard !geocoding, let i = visits.lastIndex(where: { $0.name == nil }) else { return }
        // 附近已经有名字的地点直接沿用
        let target = visits[i]
        if let known = visits.first(where: { $0.name != nil && near($0, CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon)) }) {
            visits[i].name = known.name
            save()
            nameMissingPlaces()
            return
        }
        geocoding = true
        geocoder.reverseGeocodeLocation(CLLocation(latitude: target.lat, longitude: target.lon),
                                        preferredLocale: Locale(identifier: "zh_CN")) { marks, _ in
            DispatchQueue.main.async {
                self.geocoding = false
                guard let mark = marks?.first, let idx = self.visits.firstIndex(where: { $0.id == target.id }) else { return }
                let name = mark.areasOfInterest?.first ?? mark.name ?? mark.subLocality ?? mark.locality ?? "未知地点"
                self.visits[idx].name = name
                self.save()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.nameMissingPlaces() }
            }
        }
    }

    private func save() {
        if visits.count > 3000 { visits.removeFirst(visits.count - 3000) }
        guard !Store.isDemo, let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func deleteAll() {
        visits = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 查询

    /// 某一时刻在哪。
    func place(at time: Date) -> String? {
        if Store.isDemo { return Demo.spans().last(where: { $0.start <= time })?.place }
        guard let v = visits.last(where: { $0.arrive <= time.addingTimeInterval(60) }) else { return nil }
        if let depart = v.depart, time.timeIntervalSince(depart) > 30 * 60 { return nil }
        if v.depart == nil, time.timeIntervalSince(v.arrive) > 12 * 3600 { return nil }
        return v.name
    }

    /// 一段时间里依次去过的地方（相邻重复的合并）。
    func places(from: Date, to: Date) -> [(Date, String)] {
        if Store.isDemo {
            let list: [(Date, String)] = Demo.spans().filter { $0.end > from && $0.start < to }.compactMap { s in
                guard let p = s.place else { return nil }
                return (s.start, p)
            }
            return dedupe(list)
        }
        var out: [(Date, String)] = []
        if let p = place(at: from) { out.append((from, p)) }
        for v in visits where v.arrive > from && v.arrive < to {
            if let name = v.name { out.append((v.arrive, name)) }
        }
        return dedupe(out)
    }

    /// 运动状态，合并成段，去掉 1 分钟以内的抖动。
    func activities(from: Date, to: Date) async -> [(Date, Date, Activity)] {
        if Store.isDemo { return Demo.spans().filter { $0.end > from && $0.start < to }.map { ($0.start, $0.end, $0.activity) } }
        guard Self.motionOn, CMMotionActivityManager.isActivityAvailable() else { return [] }
        let raw: [CMMotionActivity] = await withCheckedContinuation { cont in
            motion.queryActivityStarting(from: from, to: to, to: OperationQueue()) { list, _ in cont.resume(returning: list ?? []) }
        }
        var spans: [(Date, Date, Activity)] = []
        for (i, a) in raw.enumerated() {
            let kind: Activity
            if a.confidence == .low { kind = .unknown }
            else if a.automotive { kind = .driving }
            else if a.cycling { kind = .cycling }
            else if a.running { kind = .running }
            else if a.walking { kind = .walking }
            else if a.stationary { kind = .still }
            else { kind = .unknown }
            let end = i + 1 < raw.count ? raw[i + 1].startDate : to
            if kind == .unknown { continue }
            if let last = spans.last, last.2 == kind, a.startDate.timeIntervalSince(last.1) < 120 {
                spans[spans.count - 1].1 = end
            } else {
                spans.append((a.startDate, end, kind))
            }
        }
        return spans.filter { $0.1.timeIntervalSince($0.0) >= 60 || $0.2 == .driving }
    }

    /// 日程（只读，需要你在设置里开启）。
    func calendar(from: Date, to: Date) -> [(Date, Date, String, String?)] {
        if Store.isDemo { return Demo.events().filter { $0.1 > from && $0.0 < to } }
        guard Self.calendarOn, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = events.predicateForEvents(withStart: from, end: to, calendars: nil)
        return events.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { ($0.startDate, $0.endDate, $0.title ?? "日程", $0.location) }
    }

    /// 一段时间的情境：给智能体和整理用的文字描述。
    func describe(from: Date, to: Date) async -> String {
        let t = DateFormatter()
        t.dateFormat = "HH:mm"
        var rows: [String] = []
        for (start, name) in places(from: from, to: to) { rows.append("\(t.string(from: start)) 位置：\(name)") }
        for (a, b, act) in await activities(from: from, to: to) {
            rows.append("\(t.string(from: a))–\(t.string(from: b)) 状态：\(act.label)")
        }
        for (a, b, title, loc) in calendar(from: from.addingTimeInterval(-3600), to: to.addingTimeInterval(1800)) {
            rows.append("\(t.string(from: a))–\(t.string(from: b)) 日程：\(title)" + (loc.map { "（\($0)）" } ?? ""))
        }
        return rows.sorted().joined(separator: "\n")
    }

    /// 一章的情境标签：主要地点 · 主要状态。
    func setting(from: Date, to: Date) async -> String? {
        let end = max(to, from.addingTimeInterval(60))
        let place = places(from: from, to: end).last?.1
        let acts = await activities(from: from, to: end)
        var dur: [Activity: TimeInterval] = [:]
        for (a, b, k) in acts { dur[k, default: 0] += min(b, end).timeIntervalSince(max(a, from)) }
        let act = dur.max { $0.value < $1.value }?.key
        let parts = [place, act.map { $0.label }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 情境切换点：地点变了或者从静止变成乘车/步行。用来给整理切段。
    func changes(from: Date, to: Date) async -> [Date] {
        var marks: [Date] = places(from: from, to: to).dropFirst().map { $0.0 }
        let acts = await activities(from: from, to: to)
        for i in acts.indices.dropFirst() where acts[i].2 != acts[i - 1].2 && acts[i].1.timeIntervalSince(acts[i].0) > 180 {
            marks.append(acts[i].0)
        }
        return marks.sorted()
    }
}

private func dedupe(_ list: [(Date, String)]) -> [(Date, String)] {
    var out: [(Date, String)] = []
    for e in list where out.last?.1 != e.1 { out.append(e) }
    return out
}
