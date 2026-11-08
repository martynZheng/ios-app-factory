import SwiftUI

// 智能人像：模板库、肤色、美颜、姿势。
//
// 设计依据（2026-11 调研整理）：
// - 「甜水感」= 高调偏亮、低反差、柔光朦胧、粉桃肤色、背景略过曝有空气感。
//   逆光人像的做法是光源放在人物侧后方、对着人脸测光并加曝光，让背景微微过曝，再配合黑柔类的溢光效果。
// - 富士人像直出配方的共性：阴天/海边/韩系等场景普遍加曝光（+0.2~+0.5）、压高光提阴影做低反差，
//   肤色保持通透不发灰。
// - 构图：人物放三分线、视线方向留白；全身照不要切到脚踝/膝盖，手机放低到腰部微仰、脚放在画面底边附近显腿长；
//   0.5× 不要近拍人脸，环境人像用 1×，半身/特写用 2×。
// - 姿势：侧身 45°、重心放一条腿、手离开身体留出空隙、手部找事做（撩头发、托腮、遮阳、拿咖啡），
//   回头时身体跟着转，避免拍到太多眼白和颈纹。
// - 美颜：磨皮不宜过强，保留皮肤纹理，“像本人但更好看”。

// MARK: - 识别出的条件

enum LightKind: String {
    case sunny = "晴天"
    case backlight = "逆光"
    case overcast = "阴天"
    case golden = "黄昏"
    case window = "室内亮光"
    case warmIndoor = "暖光室内"
    case night = "夜晚"
}

enum SceneKind: String {
    case general = "日常"
    case beach = "海边"
    case greenery = "花草"
    case snow = "雪景"
    case cafe = "室内店铺"
    case city = "城市"
}

enum Framing: String {
    case none = "未检测到人"
    case closeUp = "特写"
    case halfBody = "半身"
    case fullBody = "全身"
    case group = "合影"
}

// MARK: - 肤色与美颜

enum SkinTone: String, CaseIterable, Identifiable {
    case smart = "智能"
    case natural = "自然"
    case fair = "冷白"
    case peach = "蜜桃"
    case warm = "暖调"
    case tan = "小麦"

    var id: String { rawValue }

    /// (提亮, 气色, 通透)。智能模式会根据画面里实际测到的肤色来决定。
    func params(sample: FaceSample?) -> (Float, Float, Float) {
        switch self {
        case .natural: return (0.25, 0.25, 0.1)
        case .fair: return (0.55, 0.15, 0.75)
        case .peach: return (0.45, 0.85, 0.25)
        case .warm: return (0.3, 0.45, -0.2)
        case .tan: return (0.1, 0.2, -0.35)
        case .smart:
            guard let s = sample else { return (0.4, 0.45, 0.3) }
            // 脸偏暗 → 多提亮；偏黄 → 多去黄；偏苍白 → 多加气色
            let brighten = Float(min(0.7, max(0.2, (0.62 - s.luma) * 2.2 + 0.3)))
            let yellow = s.red - s.blue
            let clear = Float(min(0.8, max(0.1, (yellow - 0.12) * 4 + 0.25)))
            let pale = 1 - min(1, max(0, (s.red - s.green) * 6))
            let rosy = Float(min(0.8, max(0.25, pale * 0.7 + 0.2)))
            return (brighten, rosy, clear)
        }
    }
}

enum BeautyLevel: String, CaseIterable, Identifiable {
    case off = "关"
    case light = "轻"
    case medium = "中"

    var id: String { rawValue }

    var smoothing: Float {
        switch self {
        case .off: return 0
        case .light: return 0.38
        case .medium: return 0.62
        }
    }
}

/// 画面中主角脸部的平均颜色（0~1）。
struct FaceSample: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var luma: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

// MARK: - 模板

struct PortraitTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let note: String
    var ev: Float
    var tone: FilmLook
    var smoothingBoost: Float = 1
    var backgroundSoft: Float = 0
    var tips: [String]

    static func == (a: PortraitTemplate, b: PortraitTemplate) -> Bool { a.id == b.id }

    /// 组合最终的色彩：模板色调 + 肤色设定。
    func look(skin: SkinTone, sample: FaceSample?) -> FilmLook {
        let (brighten, rosy, clear) = skin.params(sample: sample)
        // 智能肤色按 0.05 量化，避免 LUT 缓存无限增长
        func q(_ v: Float) -> Float { (v * 20).rounded() / 20 }
        var look = tone
        look.skinBrighten = q(brighten)
        look.skinRosy = q(rosy)
        look.skinClear = q(clear)
        let key = "pt-\(id)-\(skin.rawValue)-\(look.skinBrighten)-\(look.skinRosy)-\(look.skinClear)"
        return FilmLook(id: key, family: .portrait, name: name, code: name, source: "智能人像", note: note, swatch: tone.swatch)
            .tuned { l in
                l.warmth = look.warmth; l.tint = look.tint; l.saturation = look.saturation; l.chrome = look.chrome
                l.key = look.key; l.contrast = look.contrast; l.blacks = look.blacks; l.whites = look.whites
                l.shadowTint = look.shadowTint; l.highlightTint = look.highlightTint
                l.grain = look.grain; l.grainSize = look.grainSize; l.halation = look.halation
                l.vignette = look.vignette; l.glow = look.glow
                l.skinBrighten = look.skinBrighten; l.skinRosy = look.skinRosy; l.skinClear = look.skinClear
            }
    }
}

enum PortraitLibrary {
    private static func tone(_ id: String, _ c1: Color, _ c2: Color, _ f: (inout FilmLook) -> Void) -> FilmLook {
        FilmLook(id: "tone-" + id, family: .portrait, name: id, code: id, source: "", note: "", swatch: [c1, c2]).tuned { l in
            l.grain = 0.05; l.grainSize = 0.7; l.vignette = 0.05
            f(&l)
        }
    }

    static let templates: [PortraitTemplate] = [
        PortraitTemplate(
            id: "sweet-backlight", name: "甜水·逆光", note: "侧逆光、发丝金边、空气感高调",
            ev: 0.7,
            tone: tone("sweet-backlight", Color(red: 1, green: 0.86, blue: 0.84), Color(red: 1, green: 0.95, blue: 0.86)) {
                $0.warmth = 0.16; $0.tint = 0.06; $0.saturation = 0.95; $0.contrast = -0.35; $0.key = 0.12
                $0.blacks = 0.05; $0.whites = 0.97; $0.glow = 0.5; $0.halation = 0.12
                $0.highlightTint = SIMD3(0.02, 0.012, -0.004); $0.shadowTint = SIMD3(0.006, 0.0, 0.014)
            },
            smoothingBoost: 1.1, backgroundSoft: 0.5,
            tips: ["让太阳在人物侧后方，头发会镶上一圈金边", "已对脸测光：背景微微过曝更有空气感", "黑柔般的溢光已加好，适合白色/浅色衣服"]),
        PortraitTemplate(
            id: "sweet-sunny", name: "甜水·晴天", note: "明亮通透、粉桃肤色",
            ev: 0.3,
            tone: tone("sweet-sunny", Color(red: 1, green: 0.82, blue: 0.80), Color(red: 0.70, green: 0.86, blue: 0.98)) {
                $0.warmth = 0.1; $0.tint = 0.06; $0.saturation = 1.0; $0.contrast = -0.2; $0.key = 0.08
                $0.blacks = 0.035; $0.whites = 0.98; $0.glow = 0.3
                $0.highlightTint = SIMD3(0.015, 0.008, -0.004)
            },
            backgroundSoft: 0.3,
            tips: ["别让阳光直射眼睛，侧过身或背对太阳", "正午顶光会在眼窝留阴影，优先找树荫/屋檐下", "浅色衣服 + 蓝天，最出甜水感"]),
        PortraitTemplate(
            id: "overcast", name: "阴天柔光", note: "光线最柔，提亮补暖，肤色不发灰",
            ev: 0.7,
            tone: tone("overcast", Color(red: 0.98, green: 0.86, blue: 0.78), Color(red: 0.78, green: 0.80, blue: 0.84)) {
                $0.warmth = 0.22; $0.tint = 0.04; $0.saturation = 1.05; $0.contrast = 0.1; $0.key = 0.1
                $0.blacks = 0.03; $0.whites = 0.98; $0.glow = 0.22
            },
            tips: ["阴天光最柔，很适合拍特写", "尽量避开灰白的天空做背景", "已自动加曝光和暖调，皮肤更通透"]),
        PortraitTemplate(
            id: "golden", name: "黄昏金光", note: "暖金色光、温柔氛围",
            ev: 0.3,
            tone: tone("golden", Color(red: 1, green: 0.74, blue: 0.48), Color(red: 0.98, green: 0.55, blue: 0.45)) {
                $0.warmth = 0.35; $0.saturation = 1.1; $0.contrast = 0.0; $0.key = 0.04
                $0.blacks = 0.03; $0.glow = 0.38; $0.halation = 0.2
                $0.highlightTint = SIMD3(0.03, 0.015, -0.015)
            },
            backgroundSoft: 0.35,
            tips: ["日落前一小时的光最美", "侧逆光站位，让光从脸侧扫过", "眯眼笑看向太阳的方向，很有氛围"]),
        PortraitTemplate(
            id: "window", name: "窗边光", note: "侧光立体、奶油般柔和",
            ev: 0.3,
            tone: tone("window", Color(red: 1, green: 0.93, blue: 0.86), Color(red: 0.92, green: 0.84, blue: 0.80)) {
                $0.warmth = 0.08; $0.tint = 0.04; $0.saturation = 0.95; $0.contrast = -0.1; $0.key = 0.06
                $0.blacks = 0.04; $0.whites = 0.97; $0.glow = 0.3
            },
            backgroundSoft: 0.2,
            tips: ["脸朝窗户转 45°，侧光最有立体感", "有白纱帘就拉上，光会更柔", "看向窗外放空，不看镜头更自然"]),
        PortraitTemplate(
            id: "warm-indoor", name: "暖光室内", note: "校正黄光，肤色通透",
            ev: 0.3,
            tone: tone("warm-indoor", Color(red: 0.98, green: 0.86, blue: 0.80), Color(red: 0.80, green: 0.78, blue: 0.86)) {
                $0.warmth = -0.35; $0.tint = 0.03; $0.saturation = 0.92; $0.contrast = 0.05; $0.key = 0.05
                $0.blacks = 0.03; $0.glow = 0.2
            },
            tips: ["靠近光源一点，避免头顶灯直射", "已帮你校正暖黄灯，肤色不发黄", "身后有灯串的话，会变成可爱的光斑"]),
        PortraitTemplate(
            id: "cafe", name: "咖啡馆", note: "温柔生活感、轻胶片",
            ev: 0.3,
            tone: tone("cafe", Color(red: 0.92, green: 0.78, blue: 0.64), Color(red: 0.56, green: 0.42, blue: 0.36)) {
                $0.warmth = 0.05; $0.saturation = 0.95; $0.contrast = 0.15; $0.blacks = 0.03
                $0.glow = 0.25; $0.vignette = 0.15; $0.grain = 0.1
            },
            tips: ["拿着咖啡杯低头笑，是最不尴尬的姿势", "把桌上的花或甜点放进前景", "坐窗边位置，光最好"]),
        PortraitTemplate(
            id: "night", name: "夜景氛围", note: "灯光柔晕、背景光斑",
            ev: 0.0,
            tone: tone("night", Color(red: 0.98, green: 0.62, blue: 0.62), Color(red: 0.16, green: 0.20, blue: 0.40)) {
                $0.warmth = -0.1; $0.saturation = 1.05; $0.contrast = 0.2; $0.blacks = 0.02
                $0.glow = 0.42; $0.halation = 0.25; $0.grain = 0.12
            },
            smoothingBoost: 1.15,
            tips: ["找路灯、橱窗或手机屏幕照亮脸", "霓虹灯放在背景，会变成好看的光斑", "手要稳，按下快门后停半秒"]),
        PortraitTemplate(
            id: "beach", name: "海边清透", note: "冷调干净、韩系杂志感",
            ev: 0.5,
            tone: tone("beach", Color(red: 0.78, green: 0.90, blue: 0.96), Color(red: 0.98, green: 0.92, blue: 0.86)) {
                $0.warmth = -0.12; $0.saturation = 0.92; $0.contrast = 0.05; $0.key = 0.06
                $0.blacks = 0.03; $0.glow = 0.22
                $0.shadowTint = SIMD3(-0.01, 0.004, 0.02)
            },
            tips: ["海平线保持水平，放在画面上三分之一", "白裙子 + 蓝海最出片", "让风吹起头发时按快门"]),
        PortraitTemplate(
            id: "greenery", name: "花间森系", note: "朦胧前景、去掉肤色绿气",
            ev: 0.5,
            tone: tone("greenery", Color(red: 0.80, green: 0.92, blue: 0.80), Color(red: 1, green: 0.84, blue: 0.88)) {
                $0.warmth = 0.06; $0.tint = 0.1; $0.saturation = 0.9; $0.contrast = -0.15; $0.key = 0.08
                $0.blacks = 0.04; $0.glow = 0.36
            },
            backgroundSoft: 0.35,
            tips: ["把花贴近镜头做朦胧前景", "绿植会让肤色偏绿，已自动校正", "嗅花、捧花低头笑，都很自然"]),
        PortraitTemplate(
            id: "snow", name: "雪景", note: "补曝光、白得干净",
            ev: 1.0,
            tone: tone("snow", Color(red: 0.94, green: 0.96, blue: 1), Color(red: 0.96, green: 0.70, blue: 0.72)) {
                $0.warmth = -0.04; $0.saturation = 0.95; $0.contrast = 0.05; $0.glow = 0.25; $0.blacks = 0.02
            },
            tips: ["雪地会让相机拍暗，已自动加曝光", "红色或亮色衣服在雪里最跳", "接一片雪花、呵一口气，都很可爱"]),
        PortraitTemplate(
            id: "city", name: "城市街拍", note: "干净利落、低角度仰拍",
            ev: 0.3,
            tone: tone("city", Color(red: 0.86, green: 0.86, blue: 0.86), Color(red: 0.36, green: 0.46, blue: 0.56)) {
                $0.saturation = 0.95; $0.contrast = 0.3; $0.blacks = 0.02; $0.glow = 0.1; $0.vignette = 0.2
            },
            tips: ["蹲低仰拍，用天空或干净墙面做背景", "边走边拍最有松弛感", "人物放在三分线上，前方留白"]),
        PortraitTemplate(
            id: "korean", name: "韩系清透", note: "冷调干净、杂志感",
            ev: 0.5,
            tone: tone("korean", Color(red: 0.90, green: 0.92, blue: 0.96), Color(red: 0.98, green: 0.86, blue: 0.88)) {
                $0.warmth = -0.15; $0.tint = 0.03; $0.saturation = 0.9; $0.contrast = -0.1; $0.key = 0.1
                $0.blacks = 0.04; $0.whites = 0.98; $0.glow = 0.25
            },
            tips: ["纯色背景 + 简单穿搭最韩系", "表情淡一点，眼神放空", "略微过曝，皮肤更干净"]),
        PortraitTemplate(
            id: "japanese", name: "日系奶油", note: "低反差、奶油色、温柔",
            ev: 0.7,
            tone: tone("japanese", Color(red: 1, green: 0.95, blue: 0.86), Color(red: 0.86, green: 0.90, blue: 0.80)) {
                $0.warmth = 0.12; $0.saturation = 0.85; $0.contrast = -0.35; $0.key = 0.1
                $0.blacks = 0.07; $0.whites = 0.95; $0.glow = 0.3
            },
            tips: ["找干净、明亮的环境", "慵懒的动作比摆拍好看", "加一点过曝，更像胶片日杂"]),
        PortraitTemplate(
            id: "cinematic", name: "电影感", note: "青橙对比、故事感",
            ev: 0.0,
            tone: tone("cinematic", Color(red: 0.96, green: 0.66, blue: 0.42), Color(red: 0.14, green: 0.36, blue: 0.42)) {
                $0.warmth = 0.1; $0.saturation = 0.9; $0.contrast = 0.3; $0.blacks = 0.02
                $0.shadowTint = SIMD3(-0.02, 0.008, 0.03); $0.highlightTint = SIMD3(0.03, 0.012, -0.015)
                $0.grain = 0.15; $0.vignette = 0.25
            },
            smoothingBoost: 0.8,
            tips: ["不看镜头，像在等人", "侧光、硬光更有戏剧感", "横构图、人物放一侧"]),
        PortraitTemplate(
            id: "group", name: "闺蜜合影", note: "人人都好看的明亮合影",
            ev: 0.3,
            tone: tone("group", Color(red: 1, green: 0.84, blue: 0.82), Color(red: 0.80, green: 0.84, blue: 0.98)) {
                $0.warmth = 0.08; $0.tint = 0.05; $0.saturation = 1.0; $0.contrast = -0.1; $0.key = 0.06
                $0.blacks = 0.03; $0.glow = 0.22
            },
            tips: ["前后错开站，别站成一排", "身体都朝中间侧一点，更有互动感", "数 3、2、1 时连拍，总有一张大家都好看"]),
    ]

    static func template(_ id: String) -> PortraitTemplate {
        templates.first { $0.id == id } ?? templates[0]
    }

    /// 自动选择模板。
    static func choose(light: LightKind, scene: SceneKind, framing: Framing) -> PortraitTemplate {
        if framing == .group { return template("group") }
        let daylight = [LightKind.sunny, .overcast, .backlight, .golden].contains(light)
        switch scene {
        case .snow where daylight: return template("snow")
        case .beach where daylight && light != .golden: return template("beach")
        case .greenery where daylight && light != .backlight: return template("greenery")
        case .cafe where !daylight && light != .night: return template("cafe")
        default: break
        }
        switch light {
        case .backlight: return template("sweet-backlight")
        case .sunny: return template("sweet-sunny")
        case .overcast: return template("overcast")
        case .golden: return template("golden")
        case .window: return template("window")
        case .warmIndoor: return template("warm-indoor")
        case .night: return template("night")
        }
    }

    // MARK: - 讨喜小贴士（按景别）

    static func charmTips(_ framing: Framing) -> [String] {
        switch framing {
        case .closeUp:
            return ["下巴微微内收，眼睛看镜头上方一点点", "脸转 15–45°，比正脸更显小", "笑的时候眼睛微眯，像在看喜欢的人"]
        case .halfBody:
            return ["手臂别贴着身体，留一点空隙更显瘦", "肩膀放松下沉，头往一侧轻轻歪", "身体侧 45°，脸转回来看镜头"]
        case .fullBody:
            return ["重心放后腿，前脚脚尖轻点地", "双腿一前一后或交叉，腿更长", "手找点事做：提包、撩头发、遮阳"]
        case .group:
            return ["高的站后面，脸别挡住别人", "身体互相靠近，肩膀错开", "可以一起看向同一个方向笑"]
        case .none:
            return ["把人物放进取景框，我来帮你构图"]
        }
    }
}

// MARK: - 姿势库

struct PoseIdea: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let framings: Set<Framing>
}

enum PoseLibrary {
    static let all: [PoseIdea] = [
        // 全身
        PoseIdea(id: "t-step", title: "丁字步", detail: "一脚向前迈一小步，脚尖朝镜头外侧，重心在后腿", symbol: "figure.stand", framings: [.fullBody]),
        PoseIdea(id: "look-back", title: "侧身回眸", detail: "侧身背对镜头，数到 3 回头笑，身体跟着转一点", symbol: "arrow.uturn.backward", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "walk", title: "走路抓拍", detail: "朝镜头斜前方慢慢走，迈步时连拍", symbol: "figure.walk", framings: [.fullBody]),
        PoseIdea(id: "hands-back", title: "双手背后", detail: "身体侧转，双手放身后，头轻轻歪向一边", symbol: "figure.stand", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "sun-shade", title: "抬手遮阳", detail: "一只手抬到额前，手指自然张开，眯眼看远处", symbol: "sun.max", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "lean", title: "倚靠", detail: "肩膀轻靠墙或栏杆，双手环抱或插兜，状态放松", symbol: "rectangle.portrait", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "cross-legs", title: "交叉腿站", detail: "双腿交叉、脚背微绷，一手拎包", symbol: "figure.stand", framings: [.fullBody]),
        PoseIdea(id: "stretch", title: "伸懒腰", detail: "双手举高伸个懒腰，闭眼笑", symbol: "figure.wave", framings: [.fullBody, .halfBody]),
        // 坐姿
        PoseIdea(id: "sit-cross", title: "二郎腿后仰", detail: "坐下翘腿，身体微微后仰，笑着看一眼镜头", symbol: "chair", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "hug-knees", title: "台阶抱膝", detail: "坐在台阶上抱住膝盖，下巴搭在膝盖上", symbol: "chair", framings: [.fullBody, .halfBody]),
        PoseIdea(id: "squat", title: "蹲下", detail: "蹲在巷口或台阶，一手轻贴脸颊，手肘搭膝盖", symbol: "figure.stand", framings: [.fullBody]),
        // 半身 / 特写
        PoseIdea(id: "hair", title: "撩头发", detail: "低头浅笑，一手把发丝别到耳后", symbol: "wind", framings: [.halfBody, .closeUp]),
        PoseIdea(id: "chin", title: "托腮歪头", detail: "手轻托下巴（别真用力撑），头往手的方向歪", symbol: "hand.raised", framings: [.closeUp, .halfBody]),
        PoseIdea(id: "cover-mouth", title: "捂嘴笑", detail: "一手轻遮嘴，眼睛笑弯，脸看起来更小", symbol: "face.smiling", framings: [.closeUp, .halfBody]),
        PoseIdea(id: "cup-face", title: "双手捧脸", detail: "双手轻贴两颊，眨眼或嘟嘴都可爱", symbol: "heart", framings: [.closeUp]),
        PoseIdea(id: "eyes-closed", title: "闭眼笑", detail: "闭上眼睛深呼吸，睁眼的瞬间按快门", symbol: "eye.slash", framings: [.closeUp, .halfBody]),
        PoseIdea(id: "look-away", title: "看向窗外", detail: "不看镜头，望向光的方向放空", symbol: "window.vertical.open", framings: [.closeUp, .halfBody]),
        PoseIdea(id: "coffee", title: "拿杯咖啡", detail: "双手捧杯放在下巴前，低头闻一闻", symbol: "cup.and.saucer", framings: [.halfBody, .closeUp]),
        PoseIdea(id: "flowers", title: "捧花", detail: "花束抱在胸前，侧头去闻花香", symbol: "camera.macro", framings: [.halfBody, .closeUp]),
        PoseIdea(id: "collar", title: "整理衣领", detail: "低头整理衣领或耳环，抓拍最自然", symbol: "tshirt", framings: [.halfBody]),
        PoseIdea(id: "peace", title: "比耶歪头", detail: "比个耶放在脸旁，歪头眨眼", symbol: "hand.raised.fingers.spread", framings: [.closeUp, .halfBody]),
        // 合影
        PoseIdea(id: "g-lean", title: "互相依靠", detail: "头靠向彼此，肩膀前后错开", symbol: "person.2", framings: [.group]),
        PoseIdea(id: "g-walk", title: "一起走来", detail: "并排朝镜头走，边走边聊天，连拍", symbol: "figure.walk", framings: [.group]),
        PoseIdea(id: "g-jump", title: "一起跳", detail: "数到 3 一起跳起来，开连拍", symbol: "figure.jumprope", framings: [.group]),
    ]

    static func ideas(for framing: Framing) -> [PoseIdea] {
        let f: Framing = framing == .none ? .halfBody : framing
        return all.filter { $0.framings.contains(f) }
    }
}
