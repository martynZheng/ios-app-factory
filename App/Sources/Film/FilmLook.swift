import SwiftUI

/// 一种胶片风格：色彩/影调参数 + 质感参数。
/// 色彩部分会被烘焙成 3D LUT（见 FilmProcessor），质感部分（颗粒、光晕、暗角）实时叠加。
struct FilmLook: Identifiable, Equatable {
    let id: String
    let name: String      // 中文名
    let code: String      // 取景器上显示的短代号
    let note: String      // 一句话描述
    let swatch: [Color]   // 选择器上的色板

    // 影调 / 色彩（作用在 Display P3 编码值上）
    var warmth: Float = 0            // >0 偏暖
    var tint: Float = 0              // >0 偏品红，<0 偏绿
    var saturation: Float = 1
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
    var vignette: Float = 0.2        // 暗角

    func tuned(_ change: (inout FilmLook) -> Void) -> FilmLook {
        var copy = self
        change(&copy)
        return copy
    }

    static func == (lhs: FilmLook, rhs: FilmLook) -> Bool { lhs.id == rhs.id }

    static func find(_ id: String) -> FilmLook {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [FilmLook] = [
        FilmLook(id: "positive", name: "正片", code: "POS",
                 note: "反转片的浓郁与通透，暖调高光，街头扫街首选",
                 swatch: [Color(red: 0.95, green: 0.62, blue: 0.30), Color(red: 0.18, green: 0.30, blue: 0.55)])
            .tuned {
                $0.warmth = 0.30; $0.tint = 0.05; $0.saturation = 1.28; $0.contrast = 0.55
                $0.blacks = 0.015; $0.whites = 0.985
                $0.shadowTint = SIMD3(0.012, -0.004, 0.022)
                $0.highlightTint = SIMD3(0.030, 0.014, -0.022)
                $0.grain = 0.25; $0.vignette = 0.35; $0.halation = 0.10
            },
        FilmLook(id: "negative", name: "负片", code: "NEG",
                 note: "柔和低反差，青色阴影与奶油高光，日常记录",
                 swatch: [Color(red: 0.86, green: 0.78, blue: 0.62), Color(red: 0.36, green: 0.52, blue: 0.55)])
            .tuned {
                $0.warmth = 0.12; $0.saturation = 0.86; $0.contrast = -0.15
                $0.blacks = 0.06; $0.whites = 0.95
                $0.shadowTint = SIMD3(-0.012, 0.010, 0.026)
                $0.highlightTint = SIMD3(0.022, 0.012, -0.008)
                $0.grain = 0.32; $0.vignette = 0.18; $0.halation = 0.06
            },
        FilmLook(id: "hicon", name: "硬调黑白", code: "HC B&W",
                 note: "深黑与高光的强烈对撞，粗颗粒，森山大道式的街头",
                 swatch: [Color(white: 0.95), Color(white: 0.05)])
            .tuned {
                $0.mono = true; $0.monoMix = SIMD3(0.42, 0.48, 0.10)
                $0.contrast = 1.55; $0.blacks = 0; $0.whites = 1
                $0.grain = 0.65; $0.grainSize = 1.3; $0.vignette = 0.50
            },
        FilmLook(id: "chrome", name: "冷铬", code: "CHRM",
                 note: "克制的低饱和与硬朗影调，纪实与城市建筑",
                 swatch: [Color(red: 0.62, green: 0.66, blue: 0.64), Color(red: 0.20, green: 0.28, blue: 0.33)])
            .tuned {
                $0.warmth = -0.04; $0.saturation = 0.74; $0.contrast = 0.40
                $0.blacks = 0.03; $0.whites = 0.97
                $0.shadowTint = SIMD3(-0.010, 0.002, 0.016)
                $0.highlightTint = SIMD3(0.010, 0.008, 0.000)
                $0.grain = 0.18; $0.vignette = 0.22
            },
        FilmLook(id: "classicneg", name: "经典负", code: "C.NEG",
                 note: "硬朗反差加青品分离，带一点怀旧的冲印店味道",
                 swatch: [Color(red: 0.86, green: 0.52, blue: 0.48), Color(red: 0.16, green: 0.40, blue: 0.42)])
            .tuned {
                $0.warmth = 0.06; $0.tint = -0.10; $0.saturation = 0.96; $0.contrast = 0.60
                $0.blacks = 0.04; $0.whites = 0.97
                $0.shadowTint = SIMD3(-0.022, 0.004, 0.030)
                $0.highlightTint = SIMD3(0.030, 0.000, -0.012)
                $0.grain = 0.30; $0.vignette = 0.25; $0.halation = 0.14
            },
        FilmLook(id: "vivid", name: "浓彩", code: "VIVD",
                 note: "高饱和风光反转片，天空更蓝、植物更绿",
                 swatch: [Color(red: 0.98, green: 0.36, blue: 0.24), Color(red: 0.10, green: 0.42, blue: 0.80)])
            .tuned {
                $0.warmth = 0.08; $0.saturation = 1.48; $0.contrast = 0.50
                $0.blacks = 0.0; $0.whites = 1.0
                $0.highlightTint = SIMD3(0.010, 0.006, -0.006)
                $0.grain = 0.12; $0.vignette = 0.25
            },
        FilmLook(id: "silver", name: "银盐黑白", code: "SLVR",
                 note: "细腻颗粒与丰富中灰，安静的人像与静物",
                 swatch: [Color(white: 0.80), Color(white: 0.22)])
            .tuned {
                $0.mono = true; $0.monoMix = SIMD3(0.30, 0.60, 0.10)
                $0.contrast = 0.40; $0.blacks = 0.02; $0.whites = 0.97
                $0.shadowTint = SIMD3(0.000, 0.000, 0.006)
                $0.grain = 0.45; $0.grainSize = 0.75; $0.vignette = 0.25
            },
        FilmLook(id: "cine", name: "电影", code: "CINE",
                 note: "低饱和、宽容度高的电影负片，夜景高光带红晕",
                 swatch: [Color(red: 0.72, green: 0.58, blue: 0.46), Color(red: 0.12, green: 0.20, blue: 0.24)])
            .tuned {
                $0.warmth = 0.05; $0.saturation = 0.72; $0.contrast = -0.10
                $0.blacks = 0.05; $0.whites = 0.93
                $0.shadowTint = SIMD3(-0.012, 0.010, 0.022)
                $0.highlightTint = SIMD3(0.016, 0.010, 0.000)
                $0.grain = 0.22; $0.vignette = 0.28; $0.halation = 0.28
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

    /// 宽 / 高
    func widthOverHeight(landscape: Bool) -> CGFloat {
        landscape ? longOverShort : 1 / longOverShort
    }

    var next: AspectRatio {
        let all = AspectRatio.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// 居中裁切到当前比例（横竖方向跟随图像本身）。
    func crop(_ image: CIImage) -> CIImage {
        let e = image.extent
        let landscape = e.width >= e.height
        let r = longOverShort
        var w = e.width
        var h = e.height
        if landscape {
            if w / h > r { w = h * r } else { h = w / r }
        } else {
            if h / w > r { h = w * r } else { w = h / r }
        }
        let rect = CGRect(x: (e.midX - w / 2).rounded(), y: (e.midY - h / 2).rounded(),
                          width: w.rounded(.down), height: h.rounded(.down))
        return image.cropped(to: rect)
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

    var next: GrainLevel {
        let all = GrainLevel.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}
