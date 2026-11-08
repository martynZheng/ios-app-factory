import Combine
import SwiftUI

struct PartnerProgress: Codable {
    var level: Int = 1
    var shards: Int = 0
}

/// 存档。新增字段都要给默认值，并在 decode 时容错，保证老存档能读。
struct GameState: Codable {
    var coins: Double = 20
    var gems: Int = 60
    var shopLevels: [Int] = []
    var partners: [String: PartnerProgress] = [:]
    var ownedOutfits: Set<String> = []
    var equipped: [String: String] = [:]
    var ownedDecor: Set<String> = []
    var lastActive: Date = Date()
    var lastSignIn: String = ""
    var heroineName: String = "小星"
    var introSeen = false
    var totalEarned: Double = 0
    var ordersDone = 0
    var recruits = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coins = (try? c.decode(Double.self, forKey: .coins)) ?? 20
        gems = (try? c.decode(Int.self, forKey: .gems)) ?? 60
        shopLevels = (try? c.decode([Int].self, forKey: .shopLevels)) ?? []
        partners = (try? c.decode([String: PartnerProgress].self, forKey: .partners)) ?? [:]
        ownedOutfits = (try? c.decode(Set<String>.self, forKey: .ownedOutfits)) ?? []
        equipped = (try? c.decode([String: String].self, forKey: .equipped)) ?? [:]
        ownedDecor = (try? c.decode(Set<String>.self, forKey: .ownedDecor)) ?? []
        lastActive = (try? c.decode(Date.self, forKey: .lastActive)) ?? Date()
        lastSignIn = (try? c.decode(String.self, forKey: .lastSignIn)) ?? ""
        heroineName = (try? c.decode(String.self, forKey: .heroineName)) ?? "小星"
        introSeen = (try? c.decode(Bool.self, forKey: .introSeen)) ?? false
        totalEarned = (try? c.decode(Double.self, forKey: .totalEarned)) ?? 0
        ordersDone = (try? c.decode(Int.self, forKey: .ordersDone)) ?? 0
        recruits = (try? c.decode(Int.self, forKey: .recruits)) ?? 0
    }
}

/// 紧急订单：限时内点击“制作”若干次即可完成，奖励一大笔金币和钻石。
struct RushOrder: Identifiable {
    let id = UUID()
    let shopID: Int
    let product: String
    let count: Int
    let required: Int
    var progress: Int = 0
    let expires: Date
    let reward: Double
    let gems: Int
}

struct Floater: Identifiable {
    let id = UUID()
    let text: String
    let shopID: Int
}

struct RecruitResult: Identifiable {
    let id = UUID()
    let partner: PartnerDef
    let isNew: Bool
}

enum UpgradeAmount: String, CaseIterable, Identifiable {
    case one = "×1"
    case ten = "×10"
    case max = "MAX"
    var id: String { rawValue }
}

final class GameStore: ObservableObject {
    @Published private(set) var state: GameState
    @Published private(set) var incomePerSecond: Double = 0
    @Published var order: RushOrder?
    @Published var offlineReward: (amount: Double, seconds: Double)?
    @Published var floaters: [Floater] = []
    @Published var toast: String?

    private var timer: Timer?
    private var nextOrderAt = Date().addingTimeInterval(45)
    private var saveCounter = 0
    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("starmall-save.json")
    }()

    init() {
        var loaded = GameState()
        if let data = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode(GameState.self, from: data) {
            loaded = decoded
        }
        state = loaded
        normalize()
        recalc()
    }

    // MARK: - 生命周期

    func start() {
        settleOffline()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick(0.2) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        state.lastActive = Date()
        save()
    }

    private func normalize() {
        if state.shopLevels.count < Catalog.shops.count {
            state.shopLevels += Array(repeating: 0, count: Catalog.shops.count - state.shopLevels.count)
        }
        if state.shopLevels[0] == 0 { state.shopLevels[0] = 1 }
        for item in Catalog.outfits where item.isFree {
            state.ownedOutfits.insert(item.id)
        }
        for (slot, id) in Catalog.defaultOutfit where state.equipped[slot.rawValue] == nil {
            state.equipped[slot.rawValue] = id
        }
    }

    private func tick(_ dt: Double) {
        let earned = incomePerSecond * dt
        state.coins += earned
        state.totalEarned += earned

        let now = Date()
        if let current = order, now > current.expires {
            order = nil
            toast = "订单超时啦，下次快一点～"
            nextOrderAt = now.addingTimeInterval(Double.random(in: 40...80))
        } else if order == nil, now > nextOrderAt {
            spawnOrder()
        }

        saveCounter += 1
        if saveCounter >= 25 { // 约 5 秒存一次
            saveCounter = 0
            state.lastActive = now
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }

    // MARK: - 离线收益

    var offlineRate: Double { 0.3 + Double(state.ownedDecor.count) * DecorItem.rateBonus }
    var offlineHours: Double { 2 + Double(state.ownedDecor.count) * DecorItem.hoursBonus }

    private func settleOffline() {
        let away = Date().timeIntervalSince(state.lastActive)
        state.lastActive = Date()
        guard away > 60, incomePerSecond > 0 else { return }
        let seconds = min(away, offlineHours * 3600)
        let amount = seconds * incomePerSecond * offlineRate
        if amount > 0 { offlineReward = (amount, seconds) }
    }

    func collectOffline(double: Bool) {
        guard let reward = offlineReward else { return }
        if double {
            guard state.gems >= 20 else { toast = "钻石不足"; return }
            state.gems -= 20
        }
        let amount = reward.amount * (double ? 2 : 1)
        state.coins += amount
        state.totalEarned += amount
        offlineReward = nil
        save()
    }

    // MARK: - 收入计算

    func level(_ shopID: Int) -> Int { state.shopLevels[shopID] }
    func isUnlocked(_ shopID: Int) -> Bool { state.shopLevels[shopID] > 0 }

    func milestonesReached(_ shopID: Int) -> Int {
        let lv = level(shopID)
        return Catalog.milestones.filter { lv >= $0 }.count
    }

    func nextMilestone(_ shopID: Int) -> Int? {
        let lv = level(shopID)
        return Catalog.milestones.first { $0 > lv }
    }

    var stars: Int {
        Catalog.shops.reduce(0) { $0 + milestonesReached($1.id) }
    }

    var charm: Int {
        var total = 0
        for slot in OutfitSlot.allCases {
            if let id = state.equipped[slot.rawValue], let item = Catalog.outfits.first(where: { $0.id == id }) {
                total += item.charm
            }
        }
        return total + state.ownedOutfits.count * 2
    }

    /// 魅力值带来的客流加成
    var charmMultiplier: Double { 1 + Double(charm) / 100 }

    var partnerPassive: Double {
        var sum = 0.0
        for def in Catalog.partners {
            guard let p = state.partners[String(def.id)] else { continue }
            let levelFactor = 1 + 0.2 * Double(p.level - 1)
            sum += def.rarity.passive * levelFactor
            if def.shopID == nil { sum += def.rarity.passive * 3 * levelFactor }
        }
        return 1 + sum
    }

    func partnerMultiplier(for shopID: Int) -> Double {
        var m = 1.0
        for def in Catalog.partners where def.shopID == shopID {
            guard let p = state.partners[String(def.id)] else { continue }
            m *= def.rarity.shopMultiplier * (1 + 0.25 * Double(p.level - 1))
        }
        return m
    }

    func shopIncome(_ shopID: Int) -> Double {
        let lv = level(shopID)
        guard lv > 0 else { return 0 }
        let def = Catalog.shops[shopID]
        let milestone = pow(2, Double(milestonesReached(shopID)))
        return def.baseIncome * Double(lv) * milestone * partnerMultiplier(for: shopID) * charmMultiplier * partnerPassive
    }

    private func recalc() {
        incomePerSecond = Catalog.shops.reduce(0) { $0 + shopIncome($1.id) }
    }

    // MARK: - 店铺

    func upgradeCost(_ shopID: Int, levels: Int) -> Double {
        let def = Catalog.shops[shopID]
        let lv = Double(level(shopID))
        let r = 1.12
        // 等比数列求和：从当前等级连升 levels 级
        return def.baseCost * pow(r, lv - 1) * (pow(r, Double(levels)) - 1) / (r - 1)
    }

    func affordableLevels(_ shopID: Int) -> Int {
        var n = 0
        while n < 500, upgradeCost(shopID, levels: n + 1) <= state.coins { n += 1 }
        return n
    }

    func levels(for amount: UpgradeAmount, shopID: Int) -> Int {
        switch amount {
        case .one: return 1
        case .ten: return 10
        case .max: return max(1, affordableLevels(shopID))
        }
    }

    func upgrade(_ shopID: Int, amount: UpgradeAmount) {
        let n = levels(for: amount, shopID: shopID)
        let cost = upgradeCost(shopID, levels: n)
        guard isUnlocked(shopID), state.coins >= cost else { return }
        let before = milestonesReached(shopID)
        state.coins -= cost
        state.shopLevels[shopID] += n
        let gained = milestonesReached(shopID) - before
        if gained > 0 {
            state.gems += gained * 10
            toast = "\(Catalog.shops[shopID].name)人气 +\(gained)★  收入翻倍！钻石 +\(gained * 10)"
        }
        recalc()
    }

    func unlock(_ shopID: Int) {
        let def = Catalog.shops[shopID]
        guard !isUnlocked(shopID), state.coins >= def.unlockCost else { return }
        state.coins -= def.unlockCost
        state.shopLevels[shopID] = 1
        state.gems += 20
        toast = "「\(def.name)」爆改完成，盛大开业！钻石 +20"
        recalc()
        save()
    }

    /// 点击店铺招揽顾客：立即获得该店 2 秒收入
    func tapShop(_ shopID: Int) {
        guard isUnlocked(shopID) else { return }
        let amount = max(1, shopIncome(shopID) * 2)
        state.coins += amount
        state.totalEarned += amount
        let floater = Floater(text: "+" + Fmt.num(amount), shopID: shopID)
        floaters.append(floater)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.floaters.removeAll { $0.id == floater.id }
        }
    }

    // MARK: - 紧急订单

    private func spawnOrder() {
        let open = Catalog.shops.filter { isUnlocked($0.id) }
        guard let shop = open.randomElement() else { return }
        let count = Int.random(in: 2...6)
        order = RushOrder(
            shopID: shop.id,
            product: shop.products.randomElement() ?? "商品",
            count: count,
            required: 4 + count,
            expires: Date().addingTimeInterval(45),
            reward: max(50, incomePerSecond * 60),
            gems: Int.random(in: 3...8)
        )
    }

    func workOnOrder() {
        guard var current = order else { return }
        current.progress += 1
        if current.progress >= current.required {
            state.coins += current.reward
            state.totalEarned += current.reward
            state.gems += current.gems
            state.ordersDone += 1
            toast = "订单完成！金币 +\(Fmt.num(current.reward))  钻石 +\(current.gems)"
            order = nil
            nextOrderAt = Date().addingTimeInterval(Double.random(in: 40...80))
            save()
        } else {
            order = current
        }
    }

    // MARK: - 伙伴招募

    func owns(_ partnerID: Int) -> Bool { state.partners[String(partnerID)] != nil }
    func progress(_ partnerID: Int) -> PartnerProgress? { state.partners[String(partnerID)] }

    static let recruitCost = 30
    static let recruitTenCost = 270

    func recruit(times: Int) -> [RecruitResult] {
        let cost = times >= 10 ? Self.recruitTenCost : Self.recruitCost * times
        guard state.gems >= cost else {
            toast = "钻石不足，完成订单和店铺里程碑可以获得钻石"
            return []
        }
        state.gems -= cost
        var results: [RecruitResult] = []
        for i in 0..<times {
            state.recruits += 1
            // 每 10 抽保底 SR 以上；第一次招募必定 SR
            let guaranteeSR = (times >= 10 && i == times - 1) || state.recruits == 1
            let roll = Double.random(in: 0..<1)
            var rarity: Rarity = roll < 0.06 ? .ssr : (roll < 0.30 ? .sr : .r)
            if guaranteeSR && rarity == .r { rarity = .sr }
            let pool = Catalog.partners.filter { $0.rarity == rarity }
            guard let pick = pool.randomElement() else { continue }
            let key = String(pick.id)
            let isNew = state.partners[key] == nil
            if isNew {
                state.partners[key] = PartnerProgress()
            } else {
                state.partners[key]?.shards += 1
            }
            results.append(RecruitResult(partner: pick, isNew: isNew))
        }
        recalc()
        save()
        return results
    }

    func shardsNeeded(_ partnerID: Int) -> Int {
        (progress(partnerID)?.level ?? 1)
    }

    func levelUpPartner(_ partnerID: Int) {
        let key = String(partnerID)
        guard var p = state.partners[key], p.shards >= p.level else { return }
        p.shards -= p.level
        p.level += 1
        state.partners[key] = p
        recalc()
        save()
    }

    // MARK: - 衣橱

    func equippedItem(_ slot: OutfitSlot) -> OutfitItem? {
        guard let id = state.equipped[slot.rawValue] else { return nil }
        return Catalog.outfits.first { $0.id == id }
    }

    func ownsOutfit(_ id: String) -> Bool { state.ownedOutfits.contains(id) }

    func buyOrEquip(_ item: OutfitItem) {
        if !ownsOutfit(item.id) {
            if item.gems > 0 {
                guard state.gems >= item.gems else { toast = "钻石不足"; return }
                state.gems -= item.gems
            } else {
                guard state.coins >= item.price else { toast = "金币不足"; return }
                state.coins -= item.price
            }
            state.ownedOutfits.insert(item.id)
            toast = "获得「\(item.name)」魅力 +\(item.charm)"
        }
        state.equipped[item.slot.rawValue] = item.id
        recalc()
        save()
    }

    var heroineLook: AvatarLook {
        let hair = equippedItem(.hair)
        let dress = equippedItem(.dress)
        let shoes = equippedItem(.shoes)
        let accessory = equippedItem(.accessory)
        let bag = equippedItem(.bag)
        return AvatarLook(
            hairStyle: AvatarHair(rawValue: hair?.style ?? 0) ?? .long,
            hair: hair?.color ?? Palette.cocoa,
            dress: dress?.color ?? .white,
            dress2: dress?.color2 ?? Palette.sky,
            dressStyle: AvatarDress(rawValue: dress?.style ?? 0) ?? .aline,
            accessory: AvatarAccessory(rawValue: accessory?.style ?? 0) ?? .none,
            accessoryColor: accessory?.color ?? Palette.pink,
            shoes: shoes?.color ?? .white,
            shoeStyle: shoes?.style ?? 0,
            bag: bag?.color ?? .clear,
            bagStyle: bag?.style ?? 0
        )
    }

    // MARK: - 家装

    func ownsDecor(_ id: String) -> Bool { state.ownedDecor.contains(id) }

    func buyDecor(_ item: DecorItem) {
        guard !ownsDecor(item.id) else { return }
        guard state.coins >= item.price else { toast = "金币不足"; return }
        state.coins -= item.price
        state.ownedDecor.insert(item.id)
        toast = "「\(item.name)」布置好啦！离线收益提升"
        save()
    }

    // MARK: - 每日 & 其他

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var canSignIn: Bool { state.lastSignIn != Self.dayFormatter.string(from: Date()) }

    func signIn() {
        guard canSignIn else { return }
        state.lastSignIn = Self.dayFormatter.string(from: Date())
        state.gems += 50
        toast = "每日签到：钻石 +50"
        save()
    }

    func finishIntro(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.heroineName = String(trimmed.prefix(8)) }
        state.introSeen = true
        save()
    }
}
