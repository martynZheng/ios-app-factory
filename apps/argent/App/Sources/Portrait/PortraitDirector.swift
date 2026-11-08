import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// 一次画面分析的结果。坐标全部是相机帧内的归一化坐标（左上为原点，已转正）。
struct PortraitAnalysis {
    var faces: [CGRect] = []
    var primaryFace: CGRect?
    var faceYaw: Double = 0          // 弧度，>0 脸朝画面右侧（视线方向）
    var faceRoll: Double = 0
    var bodyTop: CGFloat?            // 人体关键点的最高/最低位置
    var ankleY: CGFloat?
    var kneeY: CGFloat?
    var hipY: CGFloat?
    var people = 0
    var framing: Framing = .none
    var faceSample: FaceSample?
    var faceLuma: Double = 0
    var frameLuma: Double = 0
}

/// 屏幕上的引导：以“目标框”为主，文字只是一两个字的补充。
/// 所有矩形都是成片区域内的归一化坐标（左上为原点）。
struct PortraitGuidance: Equatable {
    enum Silhouette: Equatable { case none, head, body }

    var target: CGRect?              // 主角应该在的位置和大小
    var current: CGRect?             // 主角现在的位置和大小
    var silhouette: Silhouette = .none
    var score: Double = 0            // 0~1，越接近目标越高
    var ready = false
    var hint: String = ""            // 简短提示：“靠近一点”“往右一点”“完美”
    var warning: String?             // 需要额外注意的问题（0.5× 变形、俯拍、切脚……）
    var suggestZoom: String?
}

/// 智能人像导演：定时取取景帧做 Vision 分析，自动挑模板、给构图引导、推荐姿势，并对脸测光。
final class PortraitDirector: ObservableObject {
    @Published private(set) var analysis = PortraitAnalysis()
    @Published private(set) var autoTemplate: PortraitTemplate = PortraitLibrary.templates[0]
    @Published private(set) var light: LightKind = .sunny
    @Published private(set) var scene: SceneKind = .general
    @Published private(set) var guidance = PortraitGuidance(hint: "把人物放进取景框")
    @Published private(set) var pose: PoseIdea?
    @Published private(set) var charmTip: String = ""

    /// 手动选择的模板（nil = 自动）
    @Published var manualTemplateID: String?

    var template: PortraitTemplate {
        if let id = manualTemplateID { return PortraitLibrary.template(id) }
        return autoTemplate
    }

    weak var camera: CameraModel?
    var aspect: AspectRatio = .r3x2
    var lookingDown = false

    private let queue = DispatchQueue(label: "argent.portrait.analysis", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private var timer: Timer?
    private var busy = false
    private var tick = 0
    private var lastSceneTick = -100
    private var lastFocus: CGPoint?
    private var lastFocusAt = Date.distantPast
    private var stableTemplateID = ""
    private var templateVotes: [String: Int] = [:]
    private var poseIndex = 0
    private var lastFraming: Framing = .none

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastFocus = nil
    }

    func nextPose() {
        let ideas = PoseLibrary.ideas(for: analysis.framing)
        guard !ideas.isEmpty else { return }
        poseIndex = (poseIndex + 1) % ideas.count
        pose = ideas[poseIndex]
    }

    // MARK: - 主循环（main）

    private func step() {
        guard !busy, let camera, let frame = camera.frames.get() else { return }
        busy = true
        tick += 1
        let classify = tick - lastSceneTick >= 8   // 约 2 秒做一次场景识别
        if classify { lastSceneTick = tick }
        let metrics = camera.lightMetrics()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.analyze(frame, classify: classify)
            DispatchQueue.main.async {
                self.busy = false
                self.apply(result.analysis, sceneTags: result.tags, metrics: metrics)
            }
        }
    }

    private func apply(_ a: PortraitAnalysis, sceneTags: [String]?, metrics: LightMetrics) {
        analysis = a
        if let tags = sceneTags { scene = Self.scene(from: tags) }
        light = Self.light(metrics: metrics, analysis: a)

        // 模板投票：连续 3 次一致才切换，避免来回跳
        let candidate = PortraitLibrary.choose(light: light, scene: scene, framing: a.framing)
        templateVotes[candidate.id, default: 0] += 1
        for key in templateVotes.keys where key != candidate.id { templateVotes[key] = 0 }
        if candidate.id != stableTemplateID, (templateVotes[candidate.id] ?? 0) >= 3 || stableTemplateID.isEmpty {
            stableTemplateID = candidate.id
            autoTemplate = candidate
        }

        if a.framing != lastFraming {
            lastFraming = a.framing
            let ideas = PoseLibrary.ideas(for: a.framing)
            poseIndex = 0
            pose = ideas.first
            charmTip = PortraitLibrary.charmTips(a.framing).randomElement() ?? ""
        }

        guidance = makeGuidance(a)
        meterOnFace(a)
    }

    /// 对脸测光对焦（节流：脸移动明显或超过 1.5 秒才更新）
    private func meterOnFace(_ a: PortraitAnalysis) {
        guard let face = a.primaryFace, let camera else { return }
        let center = CGPoint(x: face.midX, y: face.minY + face.height * 0.45)
        let moved = lastFocus.map { hypot($0.x - center.x, $0.y - center.y) > 0.05 } ?? true
        if moved || Date().timeIntervalSince(lastFocusAt) > 1.5 {
            lastFocus = center
            lastFocusAt = Date()
            camera.focus(normalized: center)
        }
    }

    // MARK: - 构图引导

    private func makeGuidance(_ a: PortraitAnalysis) -> PortraitGuidance {
        guard let camera, let face = a.primaryFace else {
            return PortraitGuidance(hint: "把人物放进取景框")
        }
        let fw = camera.frameSize.width
        let fh = camera.frameSize.height
        let crop = aspect.cropRect(in: CGRect(x: 0, y: 0, width: fw, height: fh))
        guard crop.width > 0, crop.height > 0, fw > 0, fh > 0 else { return PortraitGuidance() }

        // 帧坐标 → 成片坐标
        func toPhoto(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX * fw - crop.minX) / crop.width,
                   y: (r.minY * fh - crop.minY) / crop.height,
                   width: r.width * fw / crop.width,
                   height: r.height * fh / crop.height)
        }
        func photoY(_ y: CGFloat) -> CGFloat { (y * fh - crop.minY) / crop.height }

        let faceP = toPhoto(face)
        let isFront = camera.position == .front
        var g = PortraitGuidance()

        // 视线方向留白：脸朝右，人就放左边
        var targetX: CGFloat = 0.5
        if abs(a.faceYaw) > 0.25 {
            let side: CGFloat = a.faceYaw > 0 ? -1 : 1
            targetX = 0.5 + side * (a.framing == .closeUp ? 0.09 : 0.13)
        }
        let photoAspect = crop.width / crop.height   // 宽/高

        switch a.framing {
        case .fullBody:
            // 全身：头顶在 8%，脚在 93%，显腿长
            let top = a.bodyTop.map(photoY) ?? (faceP.minY - faceP.height * 0.3)
            let bottom = a.ankleY.map(photoY) ?? min(1.05, (a.kneeY.map(photoY) ?? faceP.maxY) + faceP.height * 2)
            let curH = max(0.05, bottom - top)
            let curW = min(0.9, curH * 0.32 / photoAspect)
            g.current = CGRect(x: faceP.midX - curW / 2, y: top, width: curW, height: curH)
            let tH: CGFloat = 0.85
            let tW = curW * tH / curH
            g.target = CGRect(x: targetX - tW / 2, y: 0.08, width: tW, height: tH)
            g.silhouette = .body
        case .group:
            let all = a.faces.map(toPhoto)
            let minX = all.map(\.minX).min() ?? faceP.minX
            let maxX = all.map(\.maxX).max() ?? faceP.maxX
            let minY = all.map(\.minY).min() ?? faceP.minY
            let maxY = all.map(\.maxY).max() ?? faceP.maxY
            g.current = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let tW = min(0.8, max(0.45, g.current!.width))
            let tH = g.current!.height * tW / max(g.current!.width, 0.01)
            g.target = CGRect(x: 0.5 - tW / 2, y: 0.30 - tH / 2, width: tW, height: tH)
            g.silhouette = .none
        default:
            // 特写/半身：眼睛在上三分线附近，脸的大小按景别
            let targetH: CGFloat = a.framing == .closeUp ? 0.34 : 0.17
            let eyeY: CGFloat = a.framing == .closeUp ? 0.40 : 0.33
            let tH = targetH
            let tW = faceP.width / max(faceP.height, 0.001) * tH
            g.current = faceP
            g.target = CGRect(x: targetX - tW / 2, y: eyeY - tH * 0.42, width: tW, height: tH)
            g.silhouette = .head
        }

        guard let target = g.target, let current = g.current else { return g }

        // 打分：位置偏差 + 大小偏差
        let dx = current.midX - target.midX
        let dy = current.midY - target.midY
        let sizeRatio = Double(current.height / max(target.height, 0.001))
        let posErr = Double(hypot(dx, dy)) / 0.16
        let sizeErr = abs(log(max(sizeRatio, 0.01))) / 0.45
        g.score = max(0, 1 - (posErr * 0.65 + sizeErr * 0.35))

        // 简短提示：先大小，再位置
        if sizeRatio < 0.78 {
            g.hint = a.framing == .fullBody ? "再近一点" : (isFront ? "靠近一点" : "走近一点")
        } else if sizeRatio > 1.3 {
            g.hint = "后退一点"
        } else if abs(dx) > 0.06 || abs(dy) > 0.06 {
            if abs(dx) >= abs(dy) {
                g.hint = isFront ? (dx > 0 ? "往左挪" : "往右挪") : (dx > 0 ? "手机往右" : "手机往左")
            } else {
                g.hint = dy > 0 ? "镜头往下" : "镜头往上"
            }
        } else if abs(a.faceRoll) > 0.35 {
            g.hint = "头摆正一点"
        } else {
            g.hint = "完美"
        }

        // 额外问题
        if let preset = camera.zoomPresets[safe: camera.zoomIndex], preset.label == "0.5×",
           a.framing == .closeUp || a.framing == .halfBody {
            g.warning = "0.5× 近拍会让脸变形"
            g.suggestZoom = "2×"
        } else if a.framing == .fullBody && lookingDown {
            g.warning = "手机放低到腰部，略往上拍更显腿长"
        } else if a.framing == .fullBody, let ankle = a.ankleY.map(photoY), ankle > 0.985 {
            g.warning = "脚快被切到了"
        } else if a.framing == .fullBody, a.ankleY == nil, let knee = a.kneeY.map(photoY), knee > 0.85 {
            g.warning = "别切在膝盖，拍到脚"
        } else if a.framing == .halfBody, let hip = a.hipY.map(photoY), abs(hip - 1) < 0.04 {
            g.warning = "底边别正好切在腰胯"
        }

        g.ready = g.score > 0.8 && g.warning == nil && g.hint == "完美"
        if g.ready { g.hint = "完美，拍！" }
        return g
    }

    // MARK: - 光线 & 场景

    private static func light(metrics: LightMetrics, analysis a: PortraitAnalysis) -> LightKind {
        let ev = metrics.ev100
        let kelvin = metrics.kelvin
        if ev < 4.5 { return .night }
        // 逆光：画面亮，但脸明显比整体暗
        if a.primaryFace != nil, ev >= 8, a.frameLuma > 0.35, a.faceLuma < a.frameLuma * 0.72 { return .backlight }
        if ev < 9 { return kelvin < 4000 ? .warmIndoor : .window }
        if kelvin < 4500 && ev < 13 { return .golden }
        if ev >= 12.5 { return .sunny }
        return .overcast
    }

    private static func scene(from tags: [String]) -> SceneKind {
        func has(_ words: [String]) -> Bool { tags.contains { t in words.contains { t.contains($0) } } }
        if has(["snow", "ski", "ice"]) { return .snow }
        if has(["beach", "ocean", "sea", "shore", "coast", "surf"]) { return .beach }
        if has(["flower", "blossom", "garden", "plant", "foliage", "grass", "tree", "forest", "meadow"]) { return .greenery }
        if has(["cafe", "coffee", "restaurant", "bar", "bakery", "dining", "kitchen", "food"]) { return .cafe }
        if has(["building", "street", "road", "city", "urban", "architecture", "skyscraper"]) { return .city }
        return .general
    }

    // MARK: - Vision（后台队列）

    private func analyze(_ frame: CIImage, classify: Bool) -> (analysis: PortraitAnalysis, tags: [String]?) {
        let extent = frame.extent
        // 缩小到 ~720 宽做分析，又快又够用
        let scale = min(1, 720 / max(extent.width, 1))
        let small = frame
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        var requests: [VNRequest] = [faceRequest, bodyRequest]
        let classifyRequest = VNClassifyImageRequest()
        if classify { requests.append(classifyRequest) }

        let handler = VNImageRequestHandler(ciImage: small, options: [:])
        try? handler.perform(requests)

        var a = PortraitAnalysis()
        // Vision 坐标原点在左下 → 转为左上
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

        let faces = (faceRequest.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        a.faces = faces.map { flip($0.boundingBox) }
        if let main = faces.first {
            a.primaryFace = flip(main.boundingBox)
            a.faceYaw = main.yaw?.doubleValue ?? 0
            a.faceRoll = main.roll?.doubleValue ?? 0
        }

        let bodies = bodyRequest.results ?? []
        a.people = max(faces.count, bodies.count)
        if let body = bodies.first, let points = try? body.recognizedPoints(.all) {
            func y(_ names: [VNHumanBodyPoseObservation.JointName]) -> CGFloat? {
                let ys = names.compactMap { n -> CGFloat? in
                    guard let p = points[n], p.confidence > 0.3 else { return nil }
                    return 1 - p.location.y
                }
                return ys.max()
            }
            a.ankleY = y([.leftAnkle, .rightAnkle])
            a.kneeY = y([.leftKnee, .rightKnee])
            a.hipY = y([.leftHip, .rightHip])
            let visible = points.values.filter { $0.confidence > 0.3 }.map { 1 - $0.location.y }
            a.bodyTop = visible.min()
        }

        // 景别
        if a.people >= 3 {
            a.framing = .group
        } else if let face = a.primaryFace {
            if a.ankleY != nil || (a.kneeY != nil && face.height < 0.12) {
                a.framing = .fullBody
            } else if face.height > 0.30 {
                a.framing = .closeUp
            } else {
                a.framing = .halfBody
            }
        }

        // 亮度：整幅与人脸平均色
        a.frameLuma = average(small, rect: small.extent).map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 } ?? 0
        if let face = a.primaryFace {
            let e = small.extent
            // 取脸中部（避开头发和背景）
            let r = CGRect(x: e.minX + (face.minX + face.width * 0.25) * e.width,
                           y: e.minY + (1 - face.maxY + face.height * 0.2) * e.height,
                           width: face.width * 0.5 * e.width,
                           height: face.height * 0.5 * e.height)
            if let c = average(small, rect: r) {
                a.faceSample = FaceSample(red: c.0, green: c.1, blue: c.2)
                a.faceLuma = a.faceSample?.luma ?? 0
            }
        }

        var tags: [String]?
        if classify {
            tags = (classifyRequest.results ?? [])
                .filter { $0.confidence > 0.25 }
                .prefix(12)
                .map { $0.identifier.lowercased() }
        }
        return (a, tags)
    }

    private func average(_ image: CIImage, rect: CGRect) -> (Double, Double, Double)? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var pixel = [UInt8](repeating: 0, count: 4)
        let bounds = avg.extent.isInfinite ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : CGRect(x: avg.extent.minX, y: avg.extent.minY, width: 1, height: 1)
        context.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}

/// 相机当前的测光数据。
struct LightMetrics {
    var ev100: Double     // 场景亮度（EV@ISO100），晴天户外约 13–15，室内约 6–9，夜晚 < 5
    var kelvin: Double    // 当前白平衡色温
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
