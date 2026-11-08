import AVKit
import CoreMotion
import SwiftUI

enum Theme {
    static let amber = Color(red: 0.93, green: 0.64, blue: 0.26)
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let line = Color.white.opacity(0.12)
    static let dim = Color.white.opacity(0.55)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 快门

struct ShutterButton: View {
    var size: CGFloat = 74
    var busy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                    .frame(width: size, height: size)
                Circle()
                    .fill(Color.white)
                    .frame(width: size - 12, height: size - 12)
                if busy {
                    ProgressRing()
                        .frame(width: size + 10, height: size + 10)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("拍摄")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ProgressRing: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// 圆形玻璃按钮（菜单等）。
struct GlassButton: View {
    let systemName: String
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct ThumbnailButton: View {
    let image: UIImage?
    var size: CGFloat = 46

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(image)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("打开相册")
    }
}

/// 主界面上唯一的“参数”：焦段。只显示数字，选中的为琥珀色。
struct FocalSelector: View {
    let presets: [ZoomPreset]
    let selected: Int
    var vertical = false
    let onSelect: (Int) -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(presets) { preset in
                let isOn = preset.id == selected
                Button {
                    onSelect(preset.id)
                } label: {
                    Text(preset.focal.replacingOccurrences(of: "mm", with: ""))
                        .font(Theme.mono(isOn ? 14 : 12, isOn ? .bold : .medium))
                        .foregroundStyle(isOn ? Theme.amber : Color.white.opacity(0.75))
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

// MARK: - 胶片色板

struct LookSwatch: View {
    let look: FilmLook
    var selected: Bool
    var width: CGFloat = 44
    var height: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Theme.amber : Color.white.opacity(0.15), lineWidth: selected ? 2 : 0.5)
            )
    }
}

// MARK: - 取景装饰

/// 成片区域以外压暗。
struct ViewfinderMask: View {
    let photoRect: CGRect

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRect(photoRect)
            }
            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// 四角取景框线。
struct FrameCorners: View {
    var length: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let i: CGFloat = 0.75
            Path { p in
                p.move(to: CGPoint(x: i, y: i + length)); p.addLine(to: CGPoint(x: i, y: i)); p.addLine(to: CGPoint(x: i + length, y: i))
                p.move(to: CGPoint(x: w - i - length, y: i)); p.addLine(to: CGPoint(x: w - i, y: i)); p.addLine(to: CGPoint(x: w - i, y: i + length))
                p.move(to: CGPoint(x: i, y: h - i - length)); p.addLine(to: CGPoint(x: i, y: h - i)); p.addLine(to: CGPoint(x: i + length, y: h - i))
                p.move(to: CGPoint(x: w - i - length, y: h - i)); p.addLine(to: CGPoint(x: w - i, y: h - i)); p.addLine(to: CGPoint(x: w - i, y: h - i - length))
            }
            .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// 取景器里的水印预览，与成片中的位置、比例一致。
struct WatermarkPreview: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            let shortSide = min(geo.size.width, geo.size.height)
            let fontSize = max(7, shortSide * Watermark.sizeRatio)
            let margin = shortSide * Watermark.marginRatio
            Text(text)
                .font(.custom(Watermark.fontName, size: fontSize))
                .kerning(fontSize * 0.03)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.45), radius: fontSize * 0.2)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, margin)
                .padding(.bottom, margin)
        }
        .allowsHitTesting(false)
    }
}

struct FocusReticle: View {
    @State private var settle = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Theme.amber, lineWidth: 1.2)
            .frame(width: 64, height: 64)
            .scaleEffect(settle ? 1 : 1.35)
            .opacity(settle ? 1 : 0.4)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { settle = true }
            }
            .allowsHitTesting(false)
    }
}

/// 曝光补偿刻度（竖直拖动取景时出现）。
struct ExposureScale: View {
    let value: Float

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", value))
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(Theme.amber)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<13, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(i % 3 == 0 ? 0.8 : 0.35))
                            .frame(width: i % 3 == 0 ? 14 : 8, height: 1)
                        if i < 12 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: 150)
                GeometryReader { geo in
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 7, height: 7)
                        .position(x: geo.size.width / 2, y: geo.size.height * CGFloat((2 - value) / 4))
                }
                .frame(width: 16, height: 150)
            }
            Text("EV")
                .font(Theme.mono(9, .semibold))
                .foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.45)))
        .allowsHitTesting(false)
    }
}

// MARK: - 水平仪

final class LevelMotion: ObservableObject {
    @Published var tilt: Double = 0
    @Published var isFlat = false
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            self.isFlat = abs(g.z) > 0.85
            let angle = atan2(g.x, -g.y) * 180 / .pi
            let residual = angle - (angle / 90).rounded() * 90
            self.tilt = self.tilt * 0.75 + residual * 0.25
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

struct LevelLine: View {
    let tilt: Double

    var body: some View {
        let level = abs(tilt) < 1
        HStack(spacing: 0) {
            Rectangle().frame(width: 30, height: 1)
            Spacer().frame(width: 16)
            Rectangle().frame(width: 30, height: 1)
        }
        .foregroundStyle(level ? Theme.amber : Color.white.opacity(0.7))
        .rotationEffect(.degrees(level ? 0 : -tilt))
        .animation(.easeOut(duration: 0.1), value: level)
        .allowsHitTesting(false)
    }
}

// MARK: - 实体按键快门（音量键 / 相机控制）

struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}
