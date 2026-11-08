import SwiftUI

/// 一种胶片风格：色彩/影调参数 + 质感参数。
/// 色彩部分会被烘焙成 3D LUT（见 FilmProcessor），质感部分（颗粒、光晕、暗角）实时叠加。
///
/// 预设来源（2026-11 调研）：
/// - 理光 GR III / IIIx：Image Control 里最受欢迎的是「正片」，其次是固件新增的「负片」和「硬调黑白」；
///   社区最流行的自定义是基于正片的 Kodak Portra（饱和 +1、色相 -4、高低调 +3、反差 -3、高光反差 -4、暗部反差 +4）。
/// - 富士：Fuji X Weekly 2026 年浏览量排名前列——Reggie's Portra（Classic Chrome，色彩 +2，高光/阴影 -1，
///   CCE 强，白平衡 +2 红 -4 蓝）、Kodachrome 64（Classic Chrome，DR200，阴影 +0.5，色彩 +2，清晰度 +3，
///   日光 +2 红 -5 蓝）、Kodak Tri-X 400（Acros，硬调粗颗粒）、CineStill 800T（Eterna，钨丝灯偏蓝 + 红晕）、
///   Pacific Blues（Classic Negative）。
/// 这里用自研的色彩模型去还原这些配方的“观感”，不是对相机内部算法的复制。
struct FilmLook: Identifiable, Equatable {
    enum Family: String, CaseIterable {
        case ricoh = "理光 GR"
        case fuji = "富士"
        case portrait = "人像"

        /// 胶片模式里可选的系列
        static let film: [Family] = [.ricoh, .fuji]
    }

    let id: String
    let family: Family
    let name: String      // 中文名
    let code: String      // 取景器上的短代号
    let source: String    // 参考的配方 / 相机模式
    let note: String      // 一句话描述
    let swatch: [Color]

    // 影调 / 色彩（作用在 Display P3 编码值上）
    var warmth: Float = 0            // >0 偏暖（≈ 白平衡偏移 +红 -蓝）
    var tint: Float = 0              // >0 偏品红，<0 偏绿
    var saturation: Float = 1
    var chrome: Float = 0            // 色彩铬效果：高饱和颜色压暗、更浓郁（≈ 富士 Color Chrome Effect）
    var key: Float = 0               // 高低调：>0 整体提亮中间调（≈ 理光 High/Low Key）
    var contrast: Float = 0          // -1...2，>1 时叠加第二次 S 曲线
    var blacks: Float = 0            // 黑位抬升（褪色感）
    var whites: Float = 1            // 白位压低（高光柔化）
    var shadowTint = SIMD3<Float>(repeating: 0)
    var highlightTint = SIMD3<Float>(repeating: 0)
    var mono = false
    var monoMix = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    // 质感
    var grain: Float = 0.25          // 颗粒强度（再乘以用户的颗粒档位）
    var grainSize: Float = 1         // 颗粒大小倍数
    var halation: Float = 0          // 高光红晕
    var vignette: Float = 0.2        // 暗角（≈ 理光 Shading）
    var glow: Float = 0              // 柔光/朦胧（甜水感、黑柔滤镜效果）

    // 肤色（只作用于肤色色相区域）
    var skinBrighten: Float = 0      // 提亮肤色
    var skinRosy: Float = 0          // 加一点粉嫩气色
    var skinClear: Float = 0         // 去黄、更通透（冷白皮方向）

    func tuned(_ change: (inout FilmLook) -> Void) -> FilmLook {
        var copy = self
        change(&copy)
        return copy
    }

    static func == (lhs: FilmLook, rhs: FilmLook) -> Bool { lhs.id == rhs.id }

    static func find(_ id: String) -> FilmLook {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [FilmLook] = ricoh + fuji

    // MARK: 理光 GR

    static let ricoh: [FilmLook] = [
        FilmLook(id: "gr-positive", family: .ricoh, name: "正片", code: "POSITIVE",
                 source: "GR Positive Film（默认）",
                 note: "GR 最受欢迎的模式：浓郁的红、通透的蓝，反差高但暗部有细节",
                 swatch: [Color(red: 0.92, green: 0.40, blue: 0.28), Color(red: 0.16, green: 0.32, blue: 0.62)])
            .tuned {
                $0.warmth = 0.12; $0.tint = 0.06; $0.saturation = 1.26; $0.chrome = 0.18
                $0.contrast = 0.50; $0.blacks = 0.012; $0.whites = 0.99
                $0.shadowTint = SIMD3(0.010, -0.006, 0.020)
                $0.highlightTint = SIMD3(0.022, 0.012, -0.016)
                $0.grain = 0.18; $0.vignette = 0.30
            },
        FilmLook(id: "gr-portra", family: .ricoh, name: "正片·人像", code: "POS PORTRA",
                 source: "GR 正片 · 饱和+1 色相-4 高低调+3 反差-3 高光-4 暗部+4",
                 note: "社区最流行的 GR 配方：明亮、低反差、暖肤色，像 Portra",
                 swatch: [Color(red: 0.96, green: 0.80, blue: 0.62), Color(red: 0.52, green: 0.62, blue: 0.60)])
            .tuned {
                $0.warmth = 0.32; $0.tint = -0.04; $0.saturation = 1.08; $0.key = 0.10
                $0.contrast = -0.30; $0.blacks = 0.05; $0.whites = 0.955
                $0.shadowTint = SIMD3(-0.006, 0.006, 0.014)
                $0.highlightTint = SIMD3(0.020, 0.012, -0.006)
                $0.grain = 0.22; $0.vignette = 0.15
            },
        FilmLook(id: "gr-negative", family: .ricoh, name: "负片", code: "NEGATIVE",
                 source: "GR Negative Film · 饱和-2 反差+3 高光反差+4",
                 note: "红色褪成朱红、绿色偏蓝，低饱和高反差，安静的城市感",
                 swatch: [Color(red: 0.80, green: 0.50, blue: 0.40), Color(red: 0.22, green: 0.42, blue: 0.46)])
            .tuned {
                $0.warmth = 0.04; $0.tint = -0.06; $0.saturation = 0.74
                $0.contrast = 0.62; $0.blacks = 0.03; $0.whites = 0.975
                $0.shadowTint = SIMD3(-0.016, 0.006, 0.026)
                $0.highlightTint = SIMD3(0.018, 0.008, -0.010)
                $0.grain = 0.26; $0.vignette = 0.22
            },
        FilmLook(id: "gr-hicon", family: .ricoh, name: "硬调黑白", code: "HI-CON B&W",
                 source: "GR High-Contrast B&W",
                 note: "深黑与高光的对撞、粗颗粒、重暗角，GR 街头摄影的标志",
                 swatch: [Color(white: 0.95), Color(white: 0.04)])
            .tuned {
                $0.mono = true; $0.monoMix = SIMD3(0.42, 0.48, 0.10)
                $0.contrast = 1.6; $0.blacks = 0; $0.whites = 1
                $0.grain = 0.70; $0.grainSize = 1.35; $0.vignette = 0.55
            },
    ]

    // MARK: 富士

    static let fuji: [FilmLook] = [
        FilmLook(id: "fx-reggie-portra", family: .fuji, name: "Portra 人像", code: "PORTRA",
                 source: "Reggie's Portra · Classic Chrome · 色彩+2 高光/阴影-1 · +2红-4蓝",
                 note: "2025–2026 最受欢迎的富士配方：柔和、暖、肤色漂亮，室内外都稳",
                 swatch: [Color(red: 0.93, green: 0.74, blue: 0.56), Color(red: 0.38, green: 0.50, blue: 0.52)])
            .tuned {
                $0.warmth = 0.34; $0.saturation = 0.98; $0.chrome = 0.30
                $0.contrast = 0.15; $0.blacks = 0.03; $0.whites = 0.965
                $0.shadowTint = SIMD3(-0.008, 0.004, 0.016)
                $0.highlightTint = SIMD3(0.016, 0.010, -0.010)
                $0.grain = 0.20; $0.grainSize = 0.8; $0.vignette = 0.12
            },
        FilmLook(id: "fx-kodachrome", family: .fuji, name: "Kodachrome", code: "K64",
                 source: "Kodachrome 64 · Classic Chrome · DR200 色彩+2 清晰度+3 · +2红-5蓝",
                 note: "经典反转片：深邃的蓝天、醇厚的红黄，影调硬朗有分量",
                 swatch: [Color(red: 0.90, green: 0.56, blue: 0.22), Color(red: 0.10, green: 0.26, blue: 0.52)])
            .tuned {
                $0.warmth = 0.40; $0.saturation = 1.08; $0.chrome = 0.40
                $0.contrast = 0.55; $0.blacks = 0.0; $0.whites = 0.985
                $0.shadowTint = SIMD3(-0.004, 0.000, 0.012)
                $0.highlightTint = SIMD3(0.014, 0.008, -0.012)
                $0.grain = 0.14; $0.grainSize = 0.8; $0.vignette = 0.18
            },
        FilmLook(id: "fx-pacific", family: .fuji, name: "太平洋蓝", code: "PACIFIC",
                 source: "Pacific Blues · Classic Negative",
                 note: "Classic Negative 的青蓝阴影与硬朗反差，海边与阴天最出片",
                 swatch: [Color(red: 0.74, green: 0.80, blue: 0.80), Color(red: 0.10, green: 0.32, blue: 0.44)])
            .tuned {
                $0.warmth = -0.12; $0.tint = -0.06; $0.saturation = 0.92; $0.chrome = 0.20
                $0.contrast = 0.62; $0.blacks = 0.035; $0.whites = 0.97
                $0.shadowTint = SIMD3(-0.024, 0.008, 0.034)
                $0.highlightTint = SIMD3(0.020, 0.006, -0.004)
                $0.grain = 0.28; $0.vignette = 0.20; $0.halation = 0.06
            },
        FilmLook(id: "fx-cinestill", family: .fuji, name: "夜景 800T", code: "800T",
                 source: "CineStill 800T · Eterna · 钨丝灯白平衡",
                 note: "电影卷的冷蓝夜色，灯光边缘泛起标志性的红晕",
                 swatch: [Color(red: 0.95, green: 0.34, blue: 0.26), Color(red: 0.08, green: 0.20, blue: 0.40)])
            .tuned {
                $0.warmth = -0.55; $0.tint = 0.04; $0.saturation = 0.86
                $0.contrast = 0.10; $0.blacks = 0.045; $0.whites = 0.95
                $0.shadowTint = SIMD3(-0.010, 0.006, 0.026)
                $0.highlightTint = SIMD3(0.020, 0.010, 0.000)
                $0.grain = 0.34; $0.grainSize = 1.1; $0.vignette = 0.22; $0.halation = 0.45
            },
        FilmLook(id: "fx-trix", family: .fuji, name: "Tri-X 黑白", code: "TRI-X 400",
                 source: "Kodak Tri-X 400 · Acros · 硬调粗颗粒",
                 note: "最受欢迎的富士黑白配方：浓郁中灰、扎实颗粒，纪实感",
                 swatch: [Color(white: 0.82), Color(white: 0.12)])
            .tuned {
                $0.mono = true; $0.monoMix = SIMD3(0.36, 0.54, 0.10)
                $0.contrast = 0.85; $0.blacks = 0.01; $0.whites = 0.985
                $0.grain = 0.55; $0.grainSize = 1.15; $0.vignette = 0.25
            },
    ]
}

/// 画幅比例。
enum AspectRatio: String, CaseIterable, Identifiable {
    case r3x2 = "3:2"
    case r4x3 = "4:3"
    case r1x1 = "1:1"
    case r16x9 = "16:9"

    var id: String { rawValue }

    /// 长边 / 短边
    var longOverShort: CGFloat {
        switch self {
        case .r3x2: return 3.0 / 2.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1
        case .r16x9: return 16.0 / 9.0
        }
    }

    /// 在给定矩形里居中裁出该比例（横竖方向跟随矩形本身）。
    func cropRect(in e: CGRect) -> CGRect {
        guard e.width > 0, e.height > 0 else { return e }
        let landscape = e.width >= e.height
        let r = longOverShort
        var w = e.width
        var h = e.height
        if landscape {
            if w / h > r { w = h * r } else { h = w / r }
        } else {
            if h / w > r { h = w * r } else { w = h / r }
        }
        return CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h)
    }

    func crop(_ image: CIImage) -> CIImage {
        let r = cropRect(in: image.extent)
        let rounded = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                             width: r.width.rounded(.down), height: r.height.rounded(.down))
        return image.cropped(to: rounded)
    }
}

/// 颗粒档位。
enum GrainLevel: String, CaseIterable, Identifiable {
    case off = "无"
    case low = "弱"
    case standard = "中"
    case high = "强"

    var id: String { rawValue }

    var scale: Float {
        switch self {
        case .off: return 0
        case .low: return 0.6
        case .standard: return 1
        case .high: return 1.5
        }
    }
}

/// 取景几何：把“成片区域”尽可能大地放进屏幕，外面多出来的传感器画面压暗显示。
/// 取景渲染、取景框遮罩、对焦坐标换算都用它，保证三者完全一致。
struct ViewfinderGeometry {
    let frameSize: CGSize    // 相机帧（已转正）尺寸
    let viewSize: CGSize     // 视图尺寸（点或像素均可，只要自洽）
    let aspect: AspectRatio

    var cropInFrame: CGRect {
        aspect.cropRect(in: CGRect(origin: .zero, size: frameSize))
    }

    var scale: CGFloat {
        let p = cropInFrame
        guard p.width > 0, p.height > 0 else { return 1 }
        return min(viewSize.width / p.width, viewSize.height / p.height)
    }

    /// 成片区域在视图里的位置（y 向下）。
    var photoRect: CGRect {
        let p = cropInFrame
        let s = scale
        let w = p.width * s
        let h = p.height * s
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// 相机帧内的归一化坐标 → 视图上的点。
    func viewPoint(fromNormalized p: CGPoint) -> CGPoint {
        let s = scale
        let c = cropInFrame
        return CGPoint(x: (p.x * frameSize.width - c.midX) * s + viewSize.width / 2,
                       y: (p.y * frameSize.height - c.midY) * s + viewSize.height / 2)
    }

    func viewRect(fromNormalized r: CGRect) -> CGRect {
        let a = viewPoint(fromNormalized: r.origin)
        let b = viewPoint(fromNormalized: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// 视图上的点 → 相机帧内的归一化坐标（左上为原点）。
    func normalizedFramePoint(_ point: CGPoint) -> CGPoint {
        guard frameSize.width > 0, frameSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let s = scale
        let p = cropInFrame
        let x = p.midX + (point.x - viewSize.width / 2) / s
        let y = p.midY + (point.y - viewSize.height / 2) / s
        return CGPoint(x: x / frameSize.width, y: y / frameSize.height)
    }
}
