import SwiftUI

// 星光百货 —— 全部原创设定。
// 故事：你是刚毕业的小星，回到家乡接手外婆留下的老商场「星光百货」。商场冷清多年，
// 你要从一家奶茶小铺开始，把一间间落灰的铺位“爆改”成网红店，招募伙伴、打扮自己、布置办公室，
// 让星光百货重新闪闪发光。

// MARK: - 调色板

enum Palette {
    static let cream = Color(red: 1.00, green: 0.97, blue: 0.94)
    static let blush = Color(red: 0.98, green: 0.80, blue: 0.86)
    static let pink = Color(red: 0.95, green: 0.42, blue: 0.60)
    static let rose = Color(red: 0.86, green: 0.30, blue: 0.48)
    static let lilac = Color(red: 0.78, green: 0.71, blue: 0.95)
    static let mint = Color(red: 0.66, green: 0.90, blue: 0.81)
    static let peach = Color(red: 1.00, green: 0.80, blue: 0.64)
    static let sky = Color(red: 0.68, green: 0.84, blue: 0.98)
    static let lemon = Color(red: 1.00, green: 0.92, blue: 0.60)
    static let gold = Color(red: 0.95, green: 0.74, blue: 0.27)
    static let cocoa = Color(red: 0.42, green: 0.30, blue: 0.30)
    static let ink = Color(red: 0.33, green: 0.25, blue: 0.30)
    static let skin = Color(red: 1.00, green: 0.89, blue: 0.82)
}

// MARK: - 店铺

struct ShopDef: Identifiable {
    let id: Int
    let name: String
    let symbol: String
    let colors: [Color]          // 招牌主色、辅色
    let products: [String]
    let dusty: String            // 爆改前的样子
    let baseIncome: Double       // 1 级每秒收入
    let baseCost: Double         // 升级基础价格
    let unlockCost: Double       // 爆改开业价格

    var floor: Int { id / 3 }
}

enum Catalog {
    static let floorNames = ["1F 甜蜜生活", "2F 美丽工坊", "3F 潮流街区", "4F 星光殿堂"]

    private static func shop(_ i: Int, _ name: String, _ symbol: String, _ c1: Color, _ c2: Color,
                             _ products: [String], _ dusty: String) -> ShopDef {
        ShopDef(id: i, name: name, symbol: symbol, colors: [c1, c2], products: products, dusty: dusty,
                baseIncome: 1.5 * pow(5.2, Double(i)),
                baseCost: 8 * pow(7.2, Double(i)),
                unlockCost: i == 0 ? 0 : 60 * pow(8.6, Double(i)))
    }

    static let shops: [ShopDef] = [
        shop(0, "奶茶小铺", "cup.and.saucer.fill", Palette.peach, Palette.cocoa,
             ["芋泥波波", "草莓奶云", "桂花乌龙", "杨枝甘露"], "外婆留下的小铺子"),
        shop(1, "甜品屋", "birthday.cake.fill", Palette.blush, Palette.pink,
             ["草莓芭菲", "开心果千层", "蜜桃舒芙蕾", "抹茶可颂"], "关门很久的面包房"),
        shop(2, "花与诗", "camera.macro", Palette.mint, Palette.rose,
             ["奶油郁金香", "粉雪山玫瑰", "铃兰花束", "永生花盒"], "积灰的花鸟店"),
        shop(3, "指尖美甲", "hand.raised.fingers.spread.fill", Palette.lilac, Palette.rose,
             ["猫眼美甲", "法式甜心", "碎钻延长", "手部护理"], "冷清的理发店"),
        shop(4, "蜜桃美妆", "sparkles", Palette.pink, Palette.gold,
             ["水光唇釉", "蜜桃腮红", "星闪眼影", "气垫粉底"], "过时的化妆品柜台"),
        shop(5, "雾语香氛", "drop.fill", Palette.sky, Palette.lilac,
             ["白茶香水", "无花果蜡烛", "玫瑰身体乳", "晚香玉扩香"], "没人光顾的杂货铺"),
        shop(6, "衣橱物语", "tshirt.fill", Palette.rose, Palette.cream,
             ["法式碎花裙", "针织开衫", "缎面衬衫", "百褶短裙"], "老气的服装档口"),
        shop(7, "梦游盲盒", "gift.fill", Palette.lemon, Palette.lilac,
             ["星星兔盲盒", "云朵熊挂件", "限定隐藏款", "手办礼盒"], "倒闭的玩具店"),
        shop(8, "毛球宠物", "pawprint.fill", Palette.peach, Palette.mint,
             ["猫咪洗护", "狗狗造型", "宠物蛋糕", "蝴蝶结项圈"], "空置的储物间"),
        shop(9, "星辰珠宝", "suit.diamond.fill", Palette.sky, Palette.gold,
             ["珍珠耳坠", "月光石项链", "碎钻手链", "定制对戒"], "生锈的钟表铺"),
        shop(10, "白纱之约", "heart.fill", Palette.cream, Palette.pink,
             ["鱼尾婚纱", "头纱", "伴娘礼服", "婚礼跟拍"], "停业的照相馆"),
        shop(11, "星光高定", "crown.fill", Palette.lilac, Palette.gold,
             ["星空晚礼服", "手工刺绣长裙", "红毯造型", "高定发布会"], "顶楼废弃的大厅"),
    ]

    /// 每到这些等级，店铺收入翻倍，并获得钻石和人气星。
    static let milestones = [10, 25, 50, 100, 150, 200, 300, 400, 500]

    // MARK: 伙伴

    static let partners: [PartnerDef] = [
        PartnerDef(id: 0, name: "林小满", title: "奶茶店长", rarity: .r, shopID: 0,
                   quote: "今天也要元气满满地摇奶茶！",
                   look: AvatarLook(hairStyle: .bob, hair: Palette.cocoa, dress: Palette.peach, dress2: .white)),
        PartnerDef(id: 1, name: "苏糖糖", title: "甜品师", rarity: .sr, shopID: 1,
                   quote: "甜的东西，会让人变温柔哦。",
                   look: AvatarLook(hairStyle: .twinTails, hair: Color(red: 0.98, green: 0.72, blue: 0.80), dress: Palette.blush, dress2: .white, accessory: .bow)),
        PartnerDef(id: 2, name: "夏栀", title: "花艺师", rarity: .sr, shopID: 2,
                   quote: "每一束花，都有想说的话。",
                   look: AvatarLook(hairStyle: .long, hair: Color(red: 0.30, green: 0.22, blue: 0.20), dress: Palette.mint, dress2: .white, accessory: .flower)),
        PartnerDef(id: 3, name: "温念", title: "美甲师", rarity: .r, shopID: 3,
                   quote: "指尖也要精致到闪闪发光。",
                   look: AvatarLook(hairStyle: .bun, hair: Color(red: 0.55, green: 0.38, blue: 0.30), dress: Palette.lilac, dress2: .white)),
        PartnerDef(id: 4, name: "白露", title: "美妆博主", rarity: .sr, shopID: 4,
                   quote: "宝子们，这个色号真的绝美！",
                   look: AvatarLook(hairStyle: .wavy, hair: Color(red: 0.85, green: 0.62, blue: 0.45), dress: Palette.pink, dress2: Palette.cream, accessory: .clip)),
        PartnerDef(id: 5, name: "江月", title: "调香师", rarity: .sr, shopID: 5,
                   quote: "香气，是会说话的记忆。",
                   look: AvatarLook(hairStyle: .long, hair: Color(red: 0.20, green: 0.20, blue: 0.28), dress: Palette.sky, dress2: .white, dressStyle: .gown)),
        PartnerDef(id: 6, name: "顾晚晴", title: "时装买手", rarity: .ssr, shopID: 6,
                   quote: "穿你想穿的，就是最好的风格。",
                   look: AvatarLook(hairStyle: .sidePony, hair: Color(red: 0.24, green: 0.16, blue: 0.14), dress: Palette.rose, dress2: Palette.cream, dressStyle: .suit, accessory: .glasses)),
        PartnerDef(id: 7, name: "唐果", title: "潮玩主理人", rarity: .r, shopID: 7,
                   quote: "隐藏款，下一个一定是我的！",
                   look: AvatarLook(hairStyle: .twinTails, hair: Color(red: 0.62, green: 0.50, blue: 0.85), dress: Palette.lemon, dress2: Palette.lilac, accessory: .beret)),
        PartnerDef(id: 8, name: "陆嘉嘉", title: "宠物美容师", rarity: .r, shopID: 8,
                   quote: "毛孩子们排好队，一个一个来～",
                   look: AvatarLook(hairStyle: .bob, hair: Color(red: 0.75, green: 0.50, blue: 0.30), dress: Palette.mint, dress2: Palette.peach)),
        PartnerDef(id: 9, name: "沈星澜", title: "珠宝设计师", rarity: .ssr, shopID: 9,
                   quote: "真正的光芒，是从内心透出来的。",
                   look: AvatarLook(hairStyle: .wavy, hair: Color(red: 0.12, green: 0.12, blue: 0.16), dress: Palette.sky, dress2: Palette.gold, dressStyle: .gown, accessory: .necklace)),
        PartnerDef(id: 10, name: "叶清欢", title: "婚纱设计师", rarity: .ssr, shopID: 10,
                   quote: "每个女孩都值得一场梦。",
                   look: AvatarLook(hairStyle: .bun, hair: Color(red: 0.90, green: 0.78, blue: 0.58), dress: .white, dress2: Palette.blush, dressStyle: .gown, accessory: .tiara)),
        PartnerDef(id: 11, name: "季川", title: "金牌店长", rarity: .ssr, shopID: nil,
                   quote: "老板，放心交给我。全楼业绩，我来扛。",
                   look: AvatarLook(hairStyle: .short, hair: Color(red: 0.18, green: 0.16, blue: 0.18), dress: Color(red: 0.26, green: 0.30, blue: 0.42), dress2: .white, dressStyle: .suit)),
        PartnerDef(id: 12, name: "许默", title: "财务顾问", rarity: .sr, shopID: nil,
                   quote: "每一分钱，我都替你算得清清楚楚。",
                   look: AvatarLook(hairStyle: .short, hair: Color(red: 0.36, green: 0.26, blue: 0.22), dress: Color(red: 0.60, green: 0.66, blue: 0.72), dress2: .white, dressStyle: .suit, accessory: .glasses)),
        PartnerDef(id: 13, name: "程可颂", title: "烘焙学徒", rarity: .r, shopID: 1,
                   quote: "可颂要烤到金黄酥脆才行！",
                   look: AvatarLook(hairStyle: .bun, hair: Color(red: 0.70, green: 0.48, blue: 0.32), dress: Palette.peach, dress2: .white)),
    ]

    // MARK: 衣橱

    static let outfits: [OutfitItem] = [
        // 发型
        OutfitItem(id: "hair-long-brown", slot: .hair, name: "温柔长直发", charm: 4, price: 0, gems: 0, color: Palette.cocoa, style: AvatarHair.long.rawValue),
        OutfitItem(id: "hair-bob-honey", slot: .hair, name: "蜂蜜波波头", charm: 8, price: 500, gems: 0, color: Color(red: 0.82, green: 0.58, blue: 0.36), style: AvatarHair.bob.rawValue),
        OutfitItem(id: "hair-twin-pink", slot: .hair, name: "樱花双马尾", charm: 14, price: 8_000, gems: 0, color: Color(red: 0.98, green: 0.70, blue: 0.80), style: AvatarHair.twinTails.rawValue),
        OutfitItem(id: "hair-bun-mocha", slot: .hair, name: "摩卡丸子头", charm: 18, price: 60_000, gems: 0, color: Color(red: 0.55, green: 0.38, blue: 0.30), style: AvatarHair.bun.rawValue),
        OutfitItem(id: "hair-wavy-ash", slot: .hair, name: "雾霾蓝大波浪", charm: 30, price: 0, gems: 60, color: Color(red: 0.56, green: 0.62, blue: 0.74), style: AvatarHair.wavy.rawValue),
        OutfitItem(id: "hair-side-lilac", slot: .hair, name: "香芋紫侧马尾", charm: 36, price: 5e6, gems: 0, color: Color(red: 0.72, green: 0.60, blue: 0.90), style: AvatarHair.sidePony.rawValue),
        OutfitItem(id: "hair-wavy-gold", slot: .hair, name: "星光金卷发", charm: 70, price: 0, gems: 180, color: Color(red: 0.96, green: 0.82, blue: 0.52), style: AvatarHair.wavy.rawValue),
        // 服装
        OutfitItem(id: "dress-tee", slot: .dress, name: "白T百褶裙", charm: 4, price: 0, gems: 0, color: .white, color2: Palette.sky, style: AvatarDress.topSkirt.rawValue),
        OutfitItem(id: "dress-floral", slot: .dress, name: "法式碎花裙", charm: 10, price: 1_200, gems: 0, color: Palette.blush, color2: .white, style: AvatarDress.aline.rawValue),
        OutfitItem(id: "dress-knit", slot: .dress, name: "奶咖针织套装", charm: 16, price: 20_000, gems: 0, color: Palette.peach, color2: Palette.cocoa, style: AvatarDress.topSkirt.rawValue),
        OutfitItem(id: "dress-puff", slot: .dress, name: "泡泡袖公主裙", charm: 26, price: 300_000, gems: 0, color: Palette.lilac, color2: .white, style: AvatarDress.puff.rawValue),
        OutfitItem(id: "dress-suit", slot: .dress, name: "通勤小西装", charm: 32, price: 4e6, gems: 0, color: Palette.rose, color2: Palette.cream, style: AvatarDress.suit.rawValue),
        OutfitItem(id: "dress-satin", slot: .dress, name: "香槟缎面长裙", charm: 48, price: 0, gems: 120, color: Color(red: 0.97, green: 0.88, blue: 0.74), color2: Palette.gold, style: AvatarDress.gown.rawValue),
        OutfitItem(id: "dress-galaxy", slot: .dress, name: "星空高定礼服", charm: 120, price: 0, gems: 400, color: Color(red: 0.24, green: 0.24, blue: 0.48), color2: Palette.gold, style: AvatarDress.gown.rawValue),
        OutfitItem(id: "dress-bridal", slot: .dress, name: "云朵婚纱", charm: 90, price: 8e10, gems: 0, color: .white, color2: Palette.blush, style: AvatarDress.gown.rawValue),
        // 鞋子
        OutfitItem(id: "shoes-sneaker", slot: .shoes, name: "小白鞋", charm: 2, price: 0, gems: 0, color: .white, style: 0),
        OutfitItem(id: "shoes-mary", slot: .shoes, name: "玛丽珍鞋", charm: 6, price: 2_000, gems: 0, color: Palette.cocoa, style: 0),
        OutfitItem(id: "shoes-heels", slot: .shoes, name: "裸粉高跟鞋", charm: 12, price: 150_000, gems: 0, color: Palette.blush, style: 1),
        OutfitItem(id: "shoes-boots", slot: .shoes, name: "奶油短靴", charm: 16, price: 2e6, gems: 0, color: Palette.cream, style: 2),
        OutfitItem(id: "shoes-crystal", slot: .shoes, name: "水晶鞋", charm: 40, price: 0, gems: 150, color: Palette.sky, style: 1),
        // 饰品
        OutfitItem(id: "acc-none", slot: .accessory, name: "无", charm: 0, price: 0, gems: 0, color: .clear, style: AvatarAccessory.none.rawValue),
        OutfitItem(id: "acc-bow", slot: .accessory, name: "缎带蝴蝶结", charm: 6, price: 800, gems: 0, color: Palette.pink, style: AvatarAccessory.bow.rawValue),
        OutfitItem(id: "acc-clip", slot: .accessory, name: "珍珠发夹", charm: 10, price: 30_000, gems: 0, color: .white, style: AvatarAccessory.clip.rawValue),
        OutfitItem(id: "acc-beret", slot: .accessory, name: "法式贝雷帽", charm: 14, price: 400_000, gems: 0, color: Palette.rose, style: AvatarAccessory.beret.rawValue),
        OutfitItem(id: "acc-flower", slot: .accessory, name: "小雏菊发饰", charm: 8, price: 0, gems: 30, color: Palette.lemon, style: AvatarAccessory.flower.rawValue),
        OutfitItem(id: "acc-necklace", slot: .accessory, name: "月光石项链", charm: 30, price: 3e7, gems: 0, color: Palette.sky, style: AvatarAccessory.necklace.rawValue),
        OutfitItem(id: "acc-tiara", slot: .accessory, name: "星辰王冠", charm: 80, price: 0, gems: 300, color: Palette.gold, style: AvatarAccessory.tiara.rawValue),
        // 包包
        OutfitItem(id: "bag-none", slot: .bag, name: "无", charm: 0, price: 0, gems: 0, color: .clear, style: 0),
        OutfitItem(id: "bag-tote", slot: .bag, name: "帆布托特包", charm: 4, price: 1_500, gems: 0, color: Palette.cream, style: 2),
        OutfitItem(id: "bag-hand", slot: .bag, name: "奶油手提包", charm: 12, price: 90_000, gems: 0, color: Palette.blush, style: 1),
        OutfitItem(id: "bag-chain", slot: .bag, name: "小香链条包", charm: 28, price: 1e7, gems: 0, color: Color(red: 0.16, green: 0.16, blue: 0.18), style: 3),
        OutfitItem(id: "bag-star", slot: .bag, name: "星光晚宴包", charm: 50, price: 0, gems: 200, color: Palette.gold, style: 3),
    ]

    static let defaultOutfit: [OutfitSlot: String] = [
        .hair: "hair-long-brown", .dress: "dress-tee", .shoes: "shoes-sneaker",
        .accessory: "acc-none", .bag: "bag-none",
    ]

    // MARK: 家装（老板办公室）

    static let decor: [DecorItem] = [
        DecorItem(id: "rug", name: "云朵地毯", symbol: "cloud.fill", price: 3_000, color: Palette.blush, spot: CGPoint(x: 0.50, y: 0.86)),
        DecorItem(id: "plant", name: "琴叶榕", symbol: "leaf.fill", price: 25_000, color: Palette.mint, spot: CGPoint(x: 0.10, y: 0.66)),
        DecorItem(id: "sofa", name: "奶油沙发", symbol: "sofa.fill", price: 200_000, color: Palette.peach, spot: CGPoint(x: 0.36, y: 0.70)),
        DecorItem(id: "lamp", name: "水晶吊灯", symbol: "lightbulb.fill", price: 2e6, color: Palette.lemon, spot: CGPoint(x: 0.50, y: 0.12)),
        DecorItem(id: "candle", name: "香薰蜡烛", symbol: "flame.fill", price: 1.5e7, color: Palette.peach, spot: CGPoint(x: 0.62, y: 0.50)),
        DecorItem(id: "vanity", name: "梳妆台", symbol: "mirror.side.left", price: 1e8, color: Palette.lilac, spot: CGPoint(x: 0.86, y: 0.62)),
        DecorItem(id: "wardrobe", name: "步入式衣帽间", symbol: "hanger", price: 8e8, color: Palette.rose, spot: CGPoint(x: 0.14, y: 0.36)),
        DecorItem(id: "projector", name: "星空投影", symbol: "moon.stars.fill", price: 6e9, color: Palette.sky, spot: CGPoint(x: 0.80, y: 0.22)),
        DecorItem(id: "piano", name: "白色钢琴", symbol: "pianokeys", price: 5e10, color: .white, spot: CGPoint(x: 0.66, y: 0.74)),
        DecorItem(id: "aquarium", name: "梦幻水族箱", symbol: "fish.fill", price: 4e11, color: Palette.sky, spot: CGPoint(x: 0.34, y: 0.40)),
    ]
}

// MARK: - 伙伴

enum Rarity: String, Codable {
    case r = "R"
    case sr = "SR"
    case ssr = "SSR"

    /// 作为店长时对其店铺的加成
    var shopMultiplier: Double {
        switch self {
        case .r: return 1.5
        case .sr: return 2.5
        case .ssr: return 4
        }
    }

    /// 全商场被动加成
    var passive: Double {
        switch self {
        case .r: return 0.02
        case .sr: return 0.05
        case .ssr: return 0.12
        }
    }

    var color: Color {
        switch self {
        case .r: return Palette.sky
        case .sr: return Palette.lilac
        case .ssr: return Palette.gold
        }
    }
}

struct PartnerDef: Identifiable {
    let id: Int
    let name: String
    let title: String
    let rarity: Rarity
    let shopID: Int?          // nil = 全商场加成型伙伴
    let quote: String
    let look: AvatarLook

    var skillText: String {
        if let shopID {
            return "\(Catalog.shops[shopID].name)收入 ×\(Fmt.mult(rarity.shopMultiplier))"
        }
        return "全商场收入 +\(Int(rarity.passive * 300))%"
    }
}

// MARK: - 衣橱

enum OutfitSlot: String, CaseIterable, Codable {
    case hair = "发型"
    case dress = "服装"
    case shoes = "鞋子"
    case accessory = "饰品"
    case bag = "包包"

    var symbol: String {
        switch self {
        case .hair: return "comb.fill"
        case .dress: return "tshirt.fill"
        case .shoes: return "shoeprints.fill"
        case .accessory: return "sparkle"
        case .bag: return "handbag.fill"
        }
    }
}

struct OutfitItem: Identifiable {
    let id: String
    let slot: OutfitSlot
    let name: String
    let charm: Int
    let price: Double
    let gems: Int
    let color: Color
    var color2: Color = .white
    let style: Int

    var isFree: Bool { price == 0 && gems == 0 }
}

// MARK: - 家装

struct DecorItem: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let price: Double
    let color: Color
    let spot: CGPoint        // 在房间插画里的位置（0~1）

    /// 每件家具：离线收益比例 +6%，离线时长上限 +1 小时
    static let rateBonus = 0.06
    static let hoursBonus = 1.0
}

// MARK: - 数字格式

enum Fmt {
    private static let units: [(Double, String)] = [
        (1e44, "载"), (1e40, "正"), (1e36, "涧"), (1e32, "沟"), (1e28, "穰"), (1e24, "秭"),
        (1e20, "垓"), (1e16, "京"), (1e12, "兆"), (1e8, "亿"), (1e4, "万"),
    ]

    static func num(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        let v = max(0, value)
        for (size, name) in units where v >= size {
            return trimmed(v / size) + name
        }
        if v < 10 { return trimmed(v) }
        return String(Int(v.rounded(.down)))
    }

    private static func trimmed(_ v: Double) -> String {
        let s: String
        if v < 10 { s = String(format: "%.2f", v) } else if v < 100 { s = String(format: "%.1f", v) } else { s = String(format: "%.0f", v) }
        if s.contains(".") {
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        return s
    }

    static func mult(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600)小时\((s % 3600) / 60)分" }
        if s >= 60 { return "\(s / 60)分\(s % 60)秒" }
        return "\(s)秒"
    }
}
