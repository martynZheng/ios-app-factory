import SwiftUI

// MARK: - 助理的样子

enum BuddyMood: Equatable {
    case idle, thinking, speaking, listening, sleeping
}

/// 名字和头像。默认是一只自己会动的小白狗（代码画的）；也可以换成你自己的照片。
final class BuddyProfile: ObservableObject {
    static let shared = BuddyProfile()
    @Published var name: String
    @Published private(set) var photo: UIImage?
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("buddy.jpg")
        let saved = (UserDefaults.standard.string(forKey: "buddyName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = saved.isEmpty ? "胖胖" : saved
        if !Store.isDemo { photo = UIImage(contentsOfFile: fileURL.path) }
    }

    func rename(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        name = t.isEmpty ? "胖胖" : t
        UserDefaults.standard.set(name, forKey: "buddyName")
    }

    func setPhoto(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return }
        let target = CGSize(width: 480, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = 480 / side
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: (480 - drawn.width) / 2, y: (480 - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        if let jpeg = square.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: fileURL, options: .atomic) }
        photo = square
    }

    func clearPhoto() {
        try? FileManager.default.removeItem(at: fileURL)
        photo = nil
    }
}

// MARK: - 头像

/// 圆形头像。会呼吸、眨眼；在想的时候歪头，说话时张嘴，听你说话时竖起耳朵，深夜会打瞌睡。
struct BuddyAvatar: View {
    var mood: BuddyMood = .idle
    var size: CGFloat = 72
    @ObservedObject private var profile = BuddyProfile.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active || reduceMotion)) { timeline in
            let t = Store.isDemo ? 1.0 : timeline.date.timeIntervalSinceReferenceDate
            content(t)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Chat.ring, lineWidth: max(2, size * 0.045)))
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.35 : 0.12), radius: size * 0.14, x: 0, y: size * 0.06)
        .accessibilityLabel(profile.name)
    }

    @ViewBuilder
    private func content(_ t: Double) -> some View {
        if let photo = profile.photo {
            let breathe = 1.04 + CGFloat(sin(t * (mood == .speaking ? 7 : 1.6))) * (mood == .speaking ? 0.02 : 0.012)
            let tilt = mood == .thinking ? sin(t * 1.4) * 5 : (mood == .listening ? -4 : 0)
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(breathe)
                .rotationEffect(.degrees(tilt))
        } else {
            let dark = scheme == .dark
            Canvas { context, canvas in
                BuddyPainter(mood: mood, dark: dark).draw(&context, side: min(canvas.width, canvas.height), t: t)
            }
        }
    }
}

/// 用圆和弧线画出来的小白狗。坐标都按边长归一化。
private struct BuddyPainter {
    let mood: BuddyMood
    let dark: Bool

    private func rgb(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: alpha)
    }

    private func disc(_ c: inout GraphicsContext, _ s: CGFloat, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color) {
        c.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: r * 2 * s, height: r * 2 * s)), with: .color(color))
    }

    private func oval(_ c: inout GraphicsContext, _ s: CGFloat, _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
        c.fill(Path(ellipseIn: CGRect(x: (x - rx) * s, y: (y - ry) * s, width: rx * 2 * s, height: ry * 2 * s)), with: .color(color))
    }

    func draw(_ context: inout GraphicsContext, side s: CGFloat, t: Double) {
        let fur = rgb(0xFFFFFF)
        let shade = dark ? rgb(0xB9C0DA) : rgb(0xE3DACD)
        let earFur = rgb(0xF6F1EA)
        let inkColor = rgb(0x1E1B1A)

        // 背景
        let top = dark ? rgb(0x3A4670) : rgb(0xFFEBD6)
        let bottom = dark ? rgb(0x262F52) : rgb(0xF9D5BC)
        context.fill(Path(CGRect(x: 0, y: 0, width: s, height: s)),
                     with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: s)))

        // 节奏
        let speed: Double = mood == .speaking ? 8 : (mood == .sleeping ? 1.0 : 2.0)
        let bob = CGFloat(sin(t * speed)) * (mood == .speaking ? 0.010 : 0.007)
        var tilt: Double = 0
        switch mood {
        case .thinking: tilt = 7 + sin(t * 1.3) * 3
        case .listening: tilt = -6
        case .sleeping: tilt = 9
        default: tilt = sin(t * 0.7) * 1.5
        }

        // 身体和围巾
        var body = context
        body.translateBy(x: 0, y: bob * 0.4 * s)
        for (x, r) in [(CGFloat(0.30), CGFloat(0.16)), (0.50, 0.19), (0.70, 0.16)] {
            disc(&body, s, x, 0.985, r + 0.012, shade)
        }
        for (x, r) in [(CGFloat(0.30), CGFloat(0.16)), (0.50, 0.19), (0.70, 0.16)] {
            disc(&body, s, x, 0.99, r, fur)
        }
        let scarf = Path(roundedRect: CGRect(x: 0.33 * s, y: 0.745 * s, width: 0.34 * s, height: 0.075 * s), cornerRadius: 0.035 * s)
        body.fill(scarf, with: .color(rgb(0x8DB6EA)))
        body.fill(Path(roundedRect: CGRect(x: 0.33 * s, y: 0.772 * s, width: 0.34 * s, height: 0.02 * s), cornerRadius: 0.01 * s), with: .color(rgb(0xF4A9B8)))
        body.fill(Path(roundedRect: CGRect(x: 0.585 * s, y: 0.79 * s, width: 0.07 * s, height: 0.12 * s), cornerRadius: 0.03 * s), with: .color(rgb(0x8DB6EA)))

        // 头：绕头心转一点
        var head = context
        head.translateBy(x: 0.5 * s, y: (0.47 + bob) * s)
        head.rotate(by: .degrees(tilt))
        head.translateBy(x: -0.5 * s, y: -0.47 * s)

        // 耳朵
        let earLift: CGFloat = mood == .listening ? -0.035 : (mood == .sleeping ? 0.02 : CGFloat(sin(t * 2.3)) * 0.004)
        let ears: [(CGFloat, CGFloat, CGFloat)] = [(0.235, 0.40, 0.085), (0.205, 0.50, 0.09), (0.235, 0.60, 0.08)]
        for side in [CGFloat(1), CGFloat(-1)] {
            for (x, y, r) in ears {
                let px = side > 0 ? x : 1 - x
                disc(&head, s, px, y + earLift + 0.006, r + 0.012, shade)
            }
            for (x, y, r) in ears {
                let px = side > 0 ? x : 1 - x
                disc(&head, s, px, y + earLift, r, earFur)
            }
        }

        // 卷毛脑袋
        var curls: [(CGFloat, CGFloat, CGFloat)] = []
        for i in 0..<12 {
            let a = Double(i) / 12 * Double.pi * 2
            let wobble = CGFloat(sin(t * 1.7 + Double(i) * 1.3)) * 0.002
            curls.append((0.5 + CGFloat(cos(a)) * 0.20, 0.45 + CGFloat(sin(a)) * 0.185, 0.088 + wobble))
        }
        curls.append((0.43, 0.25, 0.10))
        curls.append((0.57, 0.25, 0.10))
        curls.append((0.50, 0.22, 0.105))
        for (x, y, r) in curls { disc(&head, s, x, y + 0.006, r + 0.012, shade) }
        for (x, y, r) in curls { disc(&head, s, x, y, r, fur) }
        oval(&head, s, 0.5, 0.46, 0.21, 0.19, fur)

        // 腮红
        disc(&head, s, 0.335, 0.565, 0.042, rgb(0xF6A6A6, 0.32))
        disc(&head, s, 0.665, 0.565, 0.042, rgb(0xF6A6A6, 0.32))

        // 眼睛
        let blinkPhase = t.truncatingRemainder(dividingBy: 4.3)
        let closed = mood == .sleeping || blinkPhase < 0.13
        var look = CGPoint.zero
        if mood == .thinking { look = CGPoint(x: 0.012, y: -0.014) }
        if mood == .listening { look = CGPoint(x: 0, y: 0.004) }
        for ex in [CGFloat(0.405), CGFloat(0.595)] {
            let x = ex + look.x, y = 0.455 + look.y
            if closed {
                var lid = Path()
                lid.move(to: CGPoint(x: (x - 0.034) * s, y: y * s))
                lid.addQuadCurve(to: CGPoint(x: (x + 0.034) * s, y: y * s), control: CGPoint(x: x * s, y: (y + 0.03) * s))
                head.stroke(lid, with: .color(inkColor), style: StrokeStyle(lineWidth: 0.02 * s, lineCap: .round))
            } else {
                let r: CGFloat = mood == .listening ? 0.041 : 0.037
                disc(&head, s, x, y, r, inkColor)
                disc(&head, s, x - 0.011, y - 0.013, 0.012, fur)
            }
        }

        // 嘴：说话时一张一合，平时微微吐舌头
        var open: CGFloat = 0.55
        switch mood {
        case .speaking: open = 0.55 + CGFloat(abs(sin(t * 9))) * 0.75
        case .sleeping: open = 0
        case .thinking: open = 0.15
        case .listening: open = 0.3
        default: open = 0.5 + CGFloat(sin(t * 3)) * 0.12
        }
        oval(&head, s, 0.5, 0.585, 0.115, 0.085, shade)
        oval(&head, s, 0.5, 0.578, 0.112, 0.082, fur)
        if open > 0.05 {
            oval(&head, s, 0.5, 0.612 + 0.014 * open, 0.034, 0.03 * open + 0.008, rgb(0x7A2E35))
            oval(&head, s, 0.5, 0.622 + 0.02 * open, 0.026, 0.024 * open + 0.004, rgb(0xF58CA0))
        }
        var smile = Path()
        smile.move(to: CGPoint(x: 0.445 * s, y: 0.592 * s))
        smile.addQuadCurve(to: CGPoint(x: 0.5 * s, y: 0.598 * s), control: CGPoint(x: 0.475 * s, y: 0.625 * s))
        smile.addQuadCurve(to: CGPoint(x: 0.555 * s, y: 0.592 * s), control: CGPoint(x: 0.525 * s, y: 0.625 * s))
        head.stroke(smile, with: .color(inkColor), style: StrokeStyle(lineWidth: 0.014 * s, lineCap: .round, lineJoin: .round))
        oval(&head, s, 0.5, 0.555, 0.04, 0.03, inkColor)
        oval(&head, s, 0.49, 0.546, 0.012, 0.007, rgb(0xFFFFFF, 0.55))

        // 在想：头顶冒三个小点
        if mood == .thinking {
            for i in 0..<3 {
                let phase = sin(t * 4 - Double(i) * 0.7)
                let alpha = 0.35 + 0.65 * max(0, phase)
                disc(&context, s, 0.70 + CGFloat(i) * 0.075, 0.16 - CGFloat(max(0, phase)) * 0.02, 0.022, (dark ? rgb(0xEFE6CF, alpha) : rgb(0x1C1C1C, alpha)))
            }
        }
    }
}

// MARK: - 对话页顶上的头像和名牌

struct BuddyHeader: View {
    let mood: BuddyMood
    var caption: String?
    let onName: () -> Void
    @ObservedObject private var profile = BuddyProfile.shared
    @State private var hop = false

    var body: some View {
        VStack(spacing: -10) {
            BuddyAvatar(mood: mood, size: 76)
                .offset(y: hop ? -10 : 0)
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { hop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { hop = false }
                    }
                }
            Button(action: onName) {
                Text(caption ?? profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Chat.ring))
                    .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: caption)
        }
    }
}
