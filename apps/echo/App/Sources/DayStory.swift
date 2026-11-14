import SwiftUI
import MapKit
import CoreLocation

// MARK: - 这一天的故事：每晚一页漫画 + 路线图
//
// 省 Token 的做法：
// 1. 不重读录音：输入是白天已经整理好的分章（标题、概括、在哪、在干嘛）和到过的地名，几百字。
// 2. 一次请求、不开思考：模型只负责“挑哪几个瞬间、每格一句话、排除什么”，用 submit_story 交结构化结果。
// 3. 按内容缓存：这一天的分章没变（sourceHash 相同）就不再请求。
// 4. 图全在本机画（粉彩引擎 + 系统地图），不调图像模型。
// 5. 固定的说明放在系统提示里、每天的数据放在最后，DeepSeek 对相同的开头有缓存。

struct StoryPanel: Codable, Hashable {
    var time: String
    var place: String?
    /// meeting / talk / desk / car / walk / meal / home / outdoor / shop / sport / rest / night
    var scene: String
    var caption: String
}

struct DayStory: Codable {
    var day: String
    var title: String
    var line: String
    var panels: [StoryPanel]
    var skipped: [String]
    var sourceHash: String
    var generatedAt: Date
}

struct RouteStop: Identifiable {
    var id: Int
    var name: String
    var time: Date
    var coordinate: CLLocationCoordinate2D
}

@MainActor
final class StoryStore: ObservableObject {
    static let shared = StoryStore()
    @Published private(set) var stories: [String: DayStory] = [:]
    @Published private(set) var working: String?
    @Published private(set) var lastError: String?
    private let fileURL: URL

    static let scenes = ["meeting", "talk", "desk", "car", "walk", "meal", "home", "outdoor", "shop", "sport", "rest", "night"]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        fileURL = base.appendingPathComponent("stories.json")
        if !Store.isDemo, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: DayStory].self, from: data) {
            stories = saved
        }
    }

    private func save() {
        guard !Store.isDemo, let data = try? JSONEncoder().encode(stories) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func seedDemo(_ story: DayStory) { stories[story.day] = story }

    // MARK: 路线

    func route(day: String) -> [RouteStop] {
        let start = Store.date(fromDayKey: day), end = start.addingTimeInterval(86_400)
        if Store.isDemo {
            let at = { (h: Int, m: Int) in Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: start) ?? start }
            return [RouteStop(id: 1, name: "文一西路", time: at(8, 52), coordinate: CLLocationCoordinate2D(latitude: 30.2862, longitude: 120.0423)),
                    RouteStop(id: 2, name: "云栖小镇", time: at(9, 18), coordinate: CLLocationCoordinate2D(latitude: 30.1336, longitude: 120.0886)),
                    RouteStop(id: 3, name: "云栖国际会展中心", time: at(9, 27), coordinate: CLLocationCoordinate2D(latitude: 30.1290, longitude: 120.0838))]
        }
        var stops: [RouteStop] = []
        for v in ContextSensor.shared.visits where v.arrive >= start && v.arrive < end {
            let c = CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon)
            // 相邻的同一个地方合并
            if let last = stops.last, CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 300 { continue }
            stops.append(RouteStop(id: stops.count + 1, name: v.name ?? "某处", time: v.arrive, coordinate: c))
        }
        return stops
    }

    // MARK: 生成

    private func sourceHash(day: String) -> String {
        let chapters = Store.shared.db.digests[day]?.chapters ?? []
        var h: UInt64 = 1469598103934665603
        for c in chapters {
            for b in (c.id.uuidString + c.title + c.summary).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        }
        return String(h, radix: 16)
    }

    /// 内容有变化、而且有可画的东西时才需要（重新）生成。
    func needsStory(day: String) -> Bool {
        let chapters = Store.shared.db.digests[day]?.chapters ?? []
        guard chapters.count >= 2 else { return false }
        return stories[day]?.sourceHash != sourceHash(day: day)
    }

    /// 晚上 9 点后画今天；也补画昨天。打开 App、夜里后台时间都会调用。
    func makeIfDue(notify: Bool = false) async {
        guard Cloud.ready, !Store.isDemo, working == nil else { return }
        let today = Store.dayKey(Date())
        let yesterday = Store.dayKey(Date().addingTimeInterval(-86_400))
        if needsStory(day: yesterday) { await make(day: yesterday, notify: false) }
        if Calendar.current.component(.hour, from: Date()) >= 21, needsStory(day: today) { await make(day: today, notify: notify) }
    }

    func make(day: String, notify: Bool = false) async {
        guard working == nil, let digest = Store.shared.db.digests[day], let chapters = digest.chapters, !chapters.isEmpty else { return }
        working = day
        lastError = nil
        defer { working = nil }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        var rows: [String] = []
        for c in chapters.sorted(by: { $0.start < $1.start }) {
            let ctx = [c.situation, c.setting].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            rows.append("\(hm.string(from: c.start))–\(hm.string(from: c.end)) \(c.title)\(ctx.isEmpty ? "" : "［\(ctx)］")：\(c.summary)")
        }
        let todos = digest.items.filter { $0.kind == .todo }.map { $0.text }.prefix(5)
        let route = self.route(day: day).map { "\(hm.string(from: $0.time)) \($0.name)" }
        let scene = digest.scene ?? ""
        // 每天的数据放在最后，前面的说明每次都一样（命中 DeepSeek 的上下文缓存）
        let prompt = """
        【场合】\(scene.isEmpty ? "（没有）" : scene)
        【路线】\(route.isEmpty ? "（没有定位）" : route.joined(separator: " → "))
        【分章】
        \(rows.joined(separator: "\n"))
        【留下的待办】\(todos.isEmpty ? "（没有）" : todos.joined(separator: "；"))
        """
        var result: DayStory?
        let hash = sourceHash(day: day)
        let str: [String: Any] = ["type": "string"]
        let panel: [String: Any] = ["type": "object", "properties": [
            "time": str, "place": str, "caption": str,
            "scene": ["type": "string", "enum": Self.scenes] as [String: Any],
        ] as [String: Any], "required": ["time", "scene", "caption"]]
        let tool = AgentTool(name: "submit_story", description: "交出这一天的漫画分镜。",
                             parameters: ["type": "object", "properties": [
                                "title": str, "line": str,
                                "panels": ["type": "array", "items": panel] as [String: Any],
                                "skipped": ["type": "array", "items": str] as [String: Any],
                             ] as [String: Any], "required": ["title", "line", "panels"]]) { args in
            let raw = args["panels"] as? [[String: Any]] ?? []
            let panels = raw.compactMap { p -> StoryPanel? in
                guard let caption = p["caption"] as? String, !caption.isEmpty else { return nil }
                let scene = (p["scene"] as? String).flatMap { Self.scenes.contains($0) ? $0 : nil } ?? "outdoor"
                return StoryPanel(time: p["time"] as? String ?? "", place: (p["place"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  scene: scene, caption: String(caption.prefix(28)))
            }
            guard panels.count >= 2 else { return ToolResult(content: "至少要 2 格。", isError: true) }
            result = DayStory(day: day, title: String((args["title"] as? String ?? "").prefix(14)), line: String((args["line"] as? String ?? "").prefix(40)),
                              panels: Array(panels.prefix(6)), skipped: (args["skipped"] as? [String] ?? []).map { String($0.prefix(20)) }.prefix(4).map { $0 },
                              sourceHash: hash, generatedAt: Date())
            return ToolResult(content: "好。", terminate: true)
        }
        do {
            _ = try await Brain.run(system: Self.system, tools: [tool], thinking: false, prompt: prompt, maxTurns: 2, web: false)
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard let story = result else {
            lastError = "这次没画出来，稍后再试。"
            return
        }
        stories[day] = story
        save()
        if notify {
            _ = await Pusher.now(title: "今天画好了：\(story.title)", body: story.line)
        }
    }

    static let system = """
    你是一个漫画分镜师，把“我”的一天画成一页四到六格的小漫画。输入是这一天已经整理好的分章、路线和待办。
    做法：
    1. 挑出 3–6 个最能代表这一天、我以后最想记得的瞬间，按时间顺序。一定要排除无关的：背景里别人的闲聊、电视声、听不清的碎片、重复的内容、没有后续的琐事。把排除掉的用几个字写进 skipped（最多 4 条）。
    2. 每一格：time 用 HH:mm；place 用路线或分章里出现的地名（没有就不填）；scene 从给定的枚举里选最贴近的画面；caption 是一句第一人称的旁白，不超过 18 个字，有画面感、有一点情绪，不要流水账。
    3. title 是这页漫画的标题，不超过 10 个字；line 是一句话总结这一天，不超过 30 个字。
    只依据输入的内容，不编造没发生的事。调用 submit_story 交结果，不要写别的。
    """
}

// MARK: - 一格漫画的画

enum PanelPainter {
    /// 一格：那个时刻的天空、地面、一个场景剪影、排线和纸纹。剪影都是暗色的，像动画背景里逆光的物体。
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, hour: CGFloat, scene: String, seed: String, dark: Bool) {
        var rng = PastelRNG(text: seed)
        var pal = SkyPalette.at(hour: hour)
        if dark { pal = pal.dimmed() }
        let w = size.width, h = size.height
        let ground = h * 0.72
        let sky = Gradient(stops: [Gradient.Stop(color: pal.zenith.color, location: 0), Gradient.Stop(color: pal.upper.color, location: 0.5),
                                   Gradient.Stop(color: pal.horizon.color, location: 1)])
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: ground)))
        // 光
        let night = hour < 5 || hour > 19.5
        let sun = CGPoint(x: w * rng.range(0.6, 0.85), y: h * rng.range(0.2, 0.35))
        let g = Gradient(colors: [pal.glow.color(0.7), pal.glow.color(0)])
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - h * 0.5, y: sun.y - h * 0.5, width: h, height: h)),
                 with: .radialGradient(g, center: sun, startRadius: 0, endRadius: h * 0.5))
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - h * 0.06, y: sun.y - h * 0.06, width: h * 0.12, height: h * 0.12)),
                 with: .color(night ? pal.glow.color : Color.white.opacity(0.95)))
        if night {
            for _ in 0..<14 {
                Brush.sparkle(&ctx, at: CGPoint(x: rng.range(0, w), y: rng.range(0, ground * 0.7)), size: rng.range(0.6, 1.8), color: pal.spark.color(0.8))
            }
        }
        // 远景和地面
        var far = Path()
        far.move(to: CGPoint(x: 0, y: ground))
        var x: CGFloat = 0
        let ph = rng.range(0, 6.28)
        while x <= w {
            far.addLine(to: CGPoint(x: x, y: ground - h * 0.06 - sin(x / w * 4 + ph) * h * 0.03))
            x += 8
        }
        far.addLine(to: CGPoint(x: w, y: ground))
        far.closeSubpath()
        ctx.fill(far, with: .color(pal.far.mix(pal.horizon, 0.3).color))
        ctx.fill(Path(CGRect(x: 0, y: ground, width: w, height: h - ground)),
                 with: .linearGradient(Gradient(colors: [pal.mid.color, pal.near.color]), startPoint: CGPoint(x: 0, y: ground), endPoint: CGPoint(x: 0, y: h)))
        // 场景剪影
        let ink = pal.near.mix(RGB(0x000000), 0.35)
        let rim = pal.glow.mix(pal.horizon, 0.4)
        glyph(&ctx, scene: scene, size: size, ground: ground, ink: ink, rim: rim, lit: pal.glow, rng: &rng)
        // 质感
        Brush.shortHatch(&ctx, in: CGRect(origin: .zero, size: size), angle: -0.9, density: 0.025, length: 4,
                         color: pal.zenith.mix(pal.cloudShade, 0.5).color(0.14), width: 0.45, rng: &rng)
        Brush.shortHatch(&ctx, in: CGRect(x: 0, y: ground, width: w, height: h - ground), angle: -0.5, density: 0.05, length: 3,
                         color: ink.color(0.3), width: 0.5, rng: &rng)
        Brush.grain(&ctx, size: size, density: 0.12, light: Color.white.opacity(0.18), dark: Color.black.opacity(0.08), rng: &rng)
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    /// 各种场景的剪影，坐标按画幅比例算。
    private static func glyph(_ ctx: inout GraphicsContext, scene: String, size: CGSize, ground: CGFloat, ink: RGB, rim: RGB, lit: RGB, rng: inout PastelRNG) {
        let w = size.width, h = size.height
        var p = Path()
        var glow: [CGRect] = []
        switch scene {
        case "meeting":
            // 长桌、两把椅子、桌上的杯子和屏幕
            p.addPath(rect(w * 0.18, ground - h * 0.16, w * 0.64, h * 0.035, r: 2))
            p.addPath(rect(w * 0.22, ground - h * 0.13, w * 0.02, h * 0.13))
            p.addPath(rect(w * 0.76, ground - h * 0.13, w * 0.02, h * 0.13))
            p.addPath(rect(w * 0.08, ground - h * 0.2, w * 0.08, h * 0.2, r: 3))
            p.addPath(rect(w * 0.84, ground - h * 0.2, w * 0.08, h * 0.2, r: 3))
            p.addPath(rect(w * 0.42, ground - h * 0.42, w * 0.22, h * 0.15, r: 2))
            p.addPath(rect(w * 0.52, ground - h * 0.27, w * 0.02, h * 0.11))
            p.addPath(rect(w * 0.3, ground - h * 0.21, w * 0.04, h * 0.05, r: 1))
            glow.append(CGRect(x: w * 0.43, y: ground - h * 0.41, width: w * 0.2, height: h * 0.13))
        case "talk":
            // 两个对话气泡
            p.addEllipse(in: CGRect(x: w * 0.14, y: ground - h * 0.5, width: w * 0.36, height: h * 0.22))
            p.move(to: CGPoint(x: w * 0.26, y: ground - h * 0.3)); p.addLine(to: CGPoint(x: w * 0.22, y: ground - h * 0.2)); p.addLine(to: CGPoint(x: w * 0.33, y: ground - h * 0.29))
            p.addEllipse(in: CGRect(x: w * 0.5, y: ground - h * 0.36, width: w * 0.34, height: h * 0.2))
            p.move(to: CGPoint(x: w * 0.72, y: ground - h * 0.18)); p.addLine(to: CGPoint(x: w * 0.78, y: ground - h * 0.08)); p.addLine(to: CGPoint(x: w * 0.66, y: ground - h * 0.17))
        case "desk":
            p.addPath(rect(w * 0.2, ground - h * 0.18, w * 0.6, h * 0.035, r: 2))
            p.addPath(rect(w * 0.24, ground - h * 0.15, w * 0.025, h * 0.15))
            p.addPath(rect(w * 0.74, ground - h * 0.15, w * 0.025, h * 0.15))
            // 笔记本电脑
            var lap = Path()
            lap.move(to: CGPoint(x: w * 0.38, y: ground - h * 0.18))
            lap.addLine(to: CGPoint(x: w * 0.41, y: ground - h * 0.34))
            lap.addLine(to: CGPoint(x: w * 0.58, y: ground - h * 0.34))
            lap.addLine(to: CGPoint(x: w * 0.6, y: ground - h * 0.18))
            lap.closeSubpath()
            p.addPath(lap)
            glow.append(CGRect(x: w * 0.42, y: ground - h * 0.32, width: w * 0.15, height: h * 0.12))
            // 台灯
            p.addPath(rect(w * 0.68, ground - h * 0.36, w * 0.012, h * 0.18))
            var shade = Path()
            shade.move(to: CGPoint(x: w * 0.64, y: ground - h * 0.33)); shade.addLine(to: CGPoint(x: w * 0.68, y: ground - h * 0.42))
            shade.addLine(to: CGPoint(x: w * 0.74, y: ground - h * 0.4)); shade.closeSubpath()
            p.addPath(shade)
        case "car":
            // 一条路、一辆车、速度线
            var road = Path()
            road.move(to: CGPoint(x: w * 0.42, y: ground)); road.addLine(to: CGPoint(x: w * 0.58, y: ground))
            road.addLine(to: CGPoint(x: w * 0.95, y: h)); road.addLine(to: CGPoint(x: w * 0.05, y: h)); road.closeSubpath()
            ctx.fill(road, with: .color(ink.mix(rim, 0.25).color(0.55)))
            p.addPath(rect(w * 0.32, ground - h * 0.02, w * 0.36, h * 0.12, r: 6))
            p.addPath(rect(w * 0.38, ground - h * 0.1, w * 0.22, h * 0.1, r: 6))
            p.addEllipse(in: CGRect(x: w * 0.36, y: ground + h * 0.07, width: w * 0.07, height: w * 0.07))
            p.addEllipse(in: CGRect(x: w * 0.57, y: ground + h * 0.07, width: w * 0.07, height: w * 0.07))
            glow.append(CGRect(x: w * 0.65, y: ground + h * 0.02, width: w * 0.04, height: h * 0.03))
            var lines = Path()
            for i in 0..<4 {
                let y = ground - h * 0.06 + CGFloat(i) * h * 0.04
                lines.move(to: CGPoint(x: w * 0.08, y: y)); lines.addLine(to: CGPoint(x: w * rng.range(0.2, 0.28), y: y))
            }
            ctx.stroke(lines, with: .color(rim.color(0.8)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case "walk":
            // 一条弯曲的小路和脚印
            var path = Path()
            path.move(to: CGPoint(x: w * 0.35, y: h)); path.addQuadCurve(to: CGPoint(x: w * 0.55, y: ground), control: CGPoint(x: w * 0.8, y: h * 0.85))
            path.addLine(to: CGPoint(x: w * 0.6, y: ground)); path.addQuadCurve(to: CGPoint(x: w * 0.6, y: h), control: CGPoint(x: w * 0.95, y: h * 0.85))
            path.closeSubpath()
            ctx.fill(path, with: .color(rim.color(0.35)))
            for i in 0..<5 {
                let t = CGFloat(i) / 5
                let cx = w * (0.5 + 0.12 * sin(t * 3)), cy = h - t * (h - ground) - h * 0.03
                p.addEllipse(in: CGRect(x: cx + (i % 2 == 0 ? -5 : 3), y: cy, width: 4, height: 6))
            }
            p.addPath(treePath(x: w * 0.18, ground: ground, h: h * 0.4))
            p.addPath(treePath(x: w * 0.84, ground: ground, h: h * 0.3))
        case "meal":
            // 碗、热气、筷子
            var bowl = Path()
            bowl.move(to: CGPoint(x: w * 0.3, y: ground - h * 0.16))
            bowl.addQuadCurve(to: CGPoint(x: w * 0.7, y: ground - h * 0.16), control: CGPoint(x: w * 0.5, y: ground + h * 0.12))
            bowl.closeSubpath()
            p.addPath(bowl)
            p.addPath(rect(w * 0.44, ground - h * 0.03, w * 0.12, h * 0.03, r: 1))
            var sticks = Path()
            sticks.move(to: CGPoint(x: w * 0.62, y: ground - h * 0.18)); sticks.addLine(to: CGPoint(x: w * 0.8, y: ground - h * 0.42))
            sticks.move(to: CGPoint(x: w * 0.65, y: ground - h * 0.17)); sticks.addLine(to: CGPoint(x: w * 0.84, y: ground - h * 0.39))
            ctx.stroke(sticks, with: .color(ink.color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var steam = Path()
            for i in 0..<3 {
                let sx = w * (0.42 + 0.08 * CGFloat(i))
                steam.move(to: CGPoint(x: sx, y: ground - h * 0.2))
                steam.addCurve(to: CGPoint(x: sx, y: ground - h * 0.48), control1: CGPoint(x: sx - 8, y: ground - h * 0.3), control2: CGPoint(x: sx + 8, y: ground - h * 0.38))
            }
            ctx.stroke(steam, with: .color(Color.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        case "home", "rest", "night":
            // 一扇亮着的窗
            p.addPath(rect(w * 0.22, ground - h * 0.42, w * 0.56, h * 0.42))
            var roof = Path()
            roof.move(to: CGPoint(x: w * 0.16, y: ground - h * 0.42)); roof.addLine(to: CGPoint(x: w * 0.5, y: ground - h * 0.62))
            roof.addLine(to: CGPoint(x: w * 0.84, y: ground - h * 0.42)); roof.closeSubpath()
            p.addPath(roof)
            glow.append(CGRect(x: w * 0.3, y: ground - h * 0.34, width: w * 0.16, height: h * 0.14))
            glow.append(CGRect(x: w * 0.54, y: ground - h * 0.34, width: w * 0.16, height: h * 0.14))
            if scene != "home" { glow.removeLast() }
        case "shop":
            p.addPath(rect(w * 0.2, ground - h * 0.36, w * 0.6, h * 0.36))
            var awning = Path()
            awning.move(to: CGPoint(x: w * 0.16, y: ground - h * 0.36)); awning.addLine(to: CGPoint(x: w * 0.84, y: ground - h * 0.36))
            awning.addLine(to: CGPoint(x: w * 0.8, y: ground - h * 0.46)); awning.addLine(to: CGPoint(x: w * 0.2, y: ground - h * 0.46)); awning.closeSubpath()
            ctx.fill(awning, with: .color(rim.mix(RGB(0xFF6B8B), 0.5).color))
            glow.append(CGRect(x: w * 0.27, y: ground - h * 0.3, width: w * 0.46, height: h * 0.16))
        case "sport":
            var track = Path()
            for i in 0..<3 {
                let y = ground + CGFloat(i + 1) * (h - ground) / 4
                track.move(to: CGPoint(x: 0, y: y)); track.addQuadCurve(to: CGPoint(x: w, y: y - h * 0.03), control: CGPoint(x: w / 2, y: y + h * 0.04))
            }
            ctx.stroke(track, with: .color(rim.color(0.7)), style: StrokeStyle(lineWidth: 1.6))
            p.addPath(treePath(x: w * 0.2, ground: ground, h: h * 0.36))
            p.addPath(treePath(x: w * 0.78, ground: ground, h: h * 0.44))
        default:
            // 户外：几棵树和远处的楼
            p.addPath(treePath(x: w * 0.22, ground: ground, h: h * 0.42))
            p.addPath(treePath(x: w * 0.36, ground: ground, h: h * 0.3))
            p.addPath(rect(w * 0.62, ground - h * 0.4, w * 0.1, h * 0.4))
            p.addPath(rect(w * 0.74, ground - h * 0.28, w * 0.12, h * 0.28))
            glow.append(CGRect(x: w * 0.645, y: ground - h * 0.33, width: w * 0.02, height: h * 0.03))
            glow.append(CGRect(x: w * 0.78, y: ground - h * 0.22, width: w * 0.02, height: h * 0.03))
        }
        ctx.fill(p, with: .color(ink.color))
        // 逆光的轮廓：受光的一侧描一笔亮色
        ctx.stroke(p.offsetBy(dx: -0.8, dy: -0.8), with: .color(rim.color(0.55)), lineWidth: 0.8)
        for r in glow {
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(lit.mix(RGB(0xFFE7A8), 0.5).color))
            let c = CGPoint(x: r.midX, y: r.midY)
            let gr = max(r.width, r.height) * 1.4
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                     with: .radialGradient(Gradient(colors: [RGB(0xFFE7A8).color(0.45), RGB(0xFFE7A8).color(0)]), center: c, startRadius: 0, endRadius: gr))
        }
    }

    private static func treePath(x: CGFloat, ground: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        p.addRect(CGRect(x: x - 1.5, y: ground - h * 0.4, width: 3, height: h * 0.4))
        p.addEllipse(in: CGRect(x: x - h * 0.28, y: ground - h, width: h * 0.56, height: h * 0.66))
        return p
    }
}

/// 一格漫画：画 + 左上角的时间牌 + 下面的旁白框。边框有一点点歪，像手画的格子。
struct ComicPanelView: View {
    let panel: StoryPanel
    let index: Int
    let day: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var hour: CGFloat {
        let parts = panel.time.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 12 }
        return CGFloat(parts[0] + parts[1] / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    let pal = SkyPalette.at(hour: hour)
                    LinearGradient(colors: [pal.zenith.color, pal.horizon.color, pal.near.color], startPoint: .top, endPoint: .bottom)
                    if let image { Image(uiImage: image).resizable().transition(.opacity) }
                }
                .task(id: "\(Int(geo.size.width))-\(scheme == .dark)") {
                    let size = geo.size, h = hour, scene = panel.scene, seed = "\(day)-\(index)-\(panel.scene)", dark = scheme == .dark
                    let key = "panel|\(seed)|\(Int(size.width))x\(Int(size.height))|\(dark)|\(panel.time)"
                    let rendered = SkyCache.shared.image(key: key, size: size, scale: min(displayScale, 2)) { ctx, sz in
                        PanelPainter.paint(&ctx, size: sz, hour: h, scene: scene, seed: seed, dark: dark)
                    }
                    withAnimation(.easeOut(duration: 0.4)) { image = rendered }
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text(panel.time)
                    .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Rectangle().fill(Color(red: 1, green: 0.88, blue: 0.35)))
                    .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 1.5))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if let place = panel.place {
                    Text(place)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(7)
                }
            }
            Text(panel.caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black)
                .lineSpacing(2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color(red: 1, green: 0.99, blue: 0.96))
                .overlay(alignment: .top) { Rectangle().fill(Color.black).frame(height: 1.5) }
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 2.2))
        .rotationEffect(.degrees(Double((index * 37) % 7 - 3) * 0.25))
        .accessibilityElement(children: .combine)
    }
}

/// 这一天的路线：经过的地方按顺序编号，连成一条线。
struct RouteMapView: View {
    let stops: [RouteStop]

    var body: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: stops.map { $0.coordinate })
                .stroke(Color(red: 0.62, green: 0.36, blue: 0.80), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6]))
            ForEach(stops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                    Text("\(stop.id)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Daylight.rgb(stop.time).mix(RGB(0x000000), 0.15).color))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .accessibilityLabel("这一天的路线：" + stops.map { $0.name }.joined(separator: "、"))
    }
}

/// 今日页上的“这一天的故事”。
struct DayStoryCard: View {
    let day: String
    @ObservedObject private var stories = StoryStore.shared
    @EnvironmentObject private var store: Store

    var body: some View {
        let story = stories.stories[day]
        let stops = stories.route(day: day)
        let chapters = store.db.digests[day]?.chapters ?? []
        if story != nil || chapters.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(story.map { $0.title.isEmpty ? "这一天" : $0.title } ?? "这一天的故事")
                        .font(Ink.serif(21, relativeTo: .title2))
                        .foregroundStyle(Ink.ink)
                    Spacer()
                    action(story)
                }
                if let story {
                    if !story.line.isEmpty {
                        Text(story.line).font(.subheadline).foregroundStyle(Ink.ink2).lineSpacing(3)
                    }
                    comic(story)
                    if !story.skipped.isEmpty {
                        Text("略过了：" + story.skipped.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(Ink.ink3)
                    }
                } else if stories.working != day {
                    Text("每晚 9 点后，它会把这一天挑几个瞬间画成一页小漫画，配上路线图。也可以现在就画。")
                        .font(.footnote).foregroundStyle(Ink.ink3).lineSpacing(3)
                }
                if stories.working == day {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("在画…").font(.footnote).foregroundStyle(Ink.ink3)
                    }
                }
                if let error = stories.lastError, stories.working == nil, story == nil {
                    Text(error).font(.footnote).foregroundStyle(Ink.vermilion)
                }
                if stops.count >= 2 {
                    RouteMapView(stops: stops)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
                    Text(stops.map { "\($0.id) \($0.name)" }.joined(separator: "  →  "))
                        .font(.caption)
                        .foregroundStyle(Ink.ink2)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ story: DayStory?) -> some View {
        if stories.working == nil, Cloud.ready, story == nil || stories.needsStory(day: day) {
            Button(story == nil ? "现在画" : "重画") {
                Task { await stories.make(day: day) }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Ink.indigo)
            .buttonStyle(.plain)
        }
    }

    /// 两列的漫画格，格子之间留白，像一页漫画。
    private func comic(_ story: DayStory) -> some View {
        let columns = [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(story.panels.enumerated()), id: \.offset) { index, panel in
                ComicPanelView(panel: panel, index: index, day: day)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 1, green: 0.99, blue: 0.96)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.85), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}
