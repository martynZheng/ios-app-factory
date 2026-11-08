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

/// 屏幕上的引导。
struct PortraitGuidance: Equatable {
    var message: String
    var arrow: Arrow?
    var ready: Bool
    var targetInPhoto: CGPoint?      // 成片区域内的归一化目标点（眼睛该在的位置）
    var suggestZoom: String?         // 建议的焦段标签，如 "2×"

    enum Arrow: Equatable {
        case left, right, up, down, back, lower
    }
}

/// 智能人像导演：定时取取景帧做 Vision 分析，自动挑模板、给构图引导、推荐姿势，并对脸测光。
final class PortraitDirector: ObservableObject {
    @Published private(set) var analysis = PortraitAnalysis()
    @Published private(set) var autoTemplate: PortraitTemplate = PortraitLibrary.templates[0]
    @Published private(set) var light: LightKind = .sunny
    @Published private(set) var scene: SceneKind = .general
    @Published private(set) var guidance = PortraitGuidance(message: "把人物放进取景框", arrow: nil, ready: false)
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
            return PortraitGuidance(message: "把人物放进取景框", arrow: nil, ready: false)
        }
        let geometry = ViewfinderGeometry(frameSize: camera.frameSize, viewSize: camera.frameSize, aspect: aspect)
        let crop = geometry.cropInFrame
        let fw = camera.frameSize.width
        let fh = camera.frameSize.height
        guard crop.width > 0, crop.height > 0, fw > 0, fh > 0 else {
            return PortraitGuidance(message: "", arrow: nil, ready: false)
        }
        // 转成成片区域内的坐标
        func toPhoto(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x * fw - crop.minX) / crop.width, y: (p.y * fh - crop.minY) / crop.height)
        }
        let eyes = toPhoto(CGPoint(x: face.midX, y: face.minY + face.height * 0.42))
        let faceTop = toPhoto(CGPoint(x: face.midX, y: face.minY)).y
        let faceH = face.height * fh / crop.height
        let headTop = faceTop - faceH * 0.35
        let isFront = camera.position == .front

        var targetX: CGFloat = 0.5
        var targetY: CGFloat = 0.36
        var suggestZoom: String?

        switch a.framing {
        case .closeUp:
            targetY = 0.40
            // 视线方向留白：脸朝右就放左三分线
            if abs(a.faceYaw) > 0.25 { targetX = a.faceYaw > 0 ? 0.40 : 0.60 }
        case .halfBody:
            targetY = 0.33
            if abs(a.faceYaw) > 0.25 { targetX = a.faceYaw > 0 ? 0.38 : 0.62 }
            if let preset = camera.zoomPresets[safe: camera.zoomIndex], preset.label == "0.5×" { suggestZoom = "2×" }
        case .fullBody:
            targetY = 0.16
        case .group:
            targetY = 0.36
        case .none:
            break
        }

        // 1. 0.5× 近拍人脸会变形
        if a.framing == .closeUp || a.framing == .halfBody,
           let preset = camera.zoomPresets[safe: camera.zoomIndex], preset.label == "0.5×" {
            return PortraitGuidance(message: "0.5× 近拍会让脸变大，换 2× 并后退两步", arrow: .back, ready: false, targetInPhoto: nil, suggestZoom: "2×")
        }

        // 2. 全身：显腿长 + 不切脚
        if a.framing == .fullBody {
            if lookingDown {
                return PortraitGuidance(message: "手机放低到腰部，镜头微微向上，显腿长", arrow: .lower, ready: false, targetInPhoto: nil, suggestZoom: nil)
            }
            if let ankle = a.ankleY.map({ toPhoto(CGPoint(x: 0.5, y: $0)).y }) {
                if ankle > 0.98 {
                    return PortraitGuidance(message: "脚快被切到了，后退半步把脚拍完整", arrow: .back, ready: false, targetInPhoto: nil, suggestZoom: nil)
                }
                if ankle < 0.84 {
                    return PortraitGuidance(message: isFront ? "离镜头近一点，让脚靠近画面底部" : "镜头往上抬一点，让脚靠近画面底边", arrow: .up, ready: false, targetInPhoto: nil, suggestZoom: nil)
                }
            } else if let knee = a.kneeY.map({ toPhoto(CGPoint(x: 0.5, y: $0)).y }), knee > 0.85 {
                return PortraitGuidance(message: "别切在膝盖，后退一步拍到脚", arrow: .back, ready: false, targetInPhoto: nil, suggestZoom: nil)
            }
        }

        // 3. 半身别切在关节
        if a.framing == .halfBody, let hip = a.hipY.map({ toPhoto(CGPoint(x: 0.5, y: $0)).y }), abs(hip - 1) < 0.04 {
            return PortraitGuidance(message: "画面底边正好切在腰胯，往前或往后挪一点", arrow: .back, ready: false, targetInPhoto: nil, suggestZoom: nil)
        }

        // 4. 头顶留白
        if headTop < 0.03 && a.framing != .closeUp {
            return PortraitGuidance(message: "头顶太挤了，镜头往上一点留出空间", arrow: .up, ready: false, targetInPhoto: CGPoint(x: targetX, y: targetY), suggestZoom: suggestZoom)
        }

        // 5. 位置：眼睛放在目标点（三分线）
        let dx = eyes.x - targetX
        let dy = eyes.y - targetY
        let tolX: CGFloat = 0.07
        let tolY: CGFloat = a.framing == .fullBody ? 0.08 : 0.06
        let target = CGPoint(x: targetX, y: targetY)
        if abs(dx) > tolX || abs(dy) > tolY {
            if abs(dx) / tolX >= abs(dy) / tolY {
                let subjectRight = dx > 0
                let msg: String
                if isFront {
                    msg = subjectRight ? "往画面左边挪一点" : "往画面右边挪一点"
                } else {
                    msg = subjectRight ? "人物偏右，手机向右移一点" : "人物偏左，手机向左移一点"
                }
                return PortraitGuidance(message: msg, arrow: subjectRight ? .right : .left, ready: false, targetInPhoto: target, suggestZoom: suggestZoom)
            } else {
                let subjectLow = dy > 0
                let msg: String
                if a.framing == .fullBody {
                    msg = subjectLow ? "人物太靠下，镜头往下一点" : "人物太靠上，镜头往上一点"
                } else {
                    msg = subjectLow ? "眼睛放到上三分线，镜头往下一点" : "人物偏上，镜头往上一点"
                }
                return PortraitGuidance(message: msg, arrow: subjectLow ? .down : .up, ready: false, targetInPhoto: target, suggestZoom: suggestZoom)
            }
        }

        // 6. 头歪太多
        if abs(a.faceRoll) > 0.35 {
            return PortraitGuidance(message: "头歪得有点多，回正一点更自然", arrow: nil, ready: false, targetInPhoto: target, suggestZoom: suggestZoom)
        }

        return PortraitGuidance(message: "构图完美，按快门吧", arrow: nil, ready: true, targetInPhoto: target, suggestZoom: suggestZoom)
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
