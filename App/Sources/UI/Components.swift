import AVKit
import CoreMotion
import SwiftUI

enum Theme {
    static let amber = Color(red: 0.93, green: 0.64, blue: 0.26)
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let panel = Color(white: 0.09)
    static let line = Color.white.opacity(0.12)
    static let dim = Color.white.opacity(0.55)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 快门

struct ShutterButton: View {
    var size: CGFloat = 76
    var busy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: size, height: size)
                Circle()
                    .fill(Color.white)
                    .frame(width: size - 14, height: size - 14)
                if busy {
                    ProgressRing()
                        .frame(width: size + 10, height: size + 10)
                }
            }
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

// MARK: - 小按钮

struct ChipButton: View {
    let title: String
    var value: String? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(active ? Theme.amber : Theme.dim)
                if let value {
                    Text(value)
                        .foregroundStyle(active ? Theme.amber : .white)
                }
            }
            .font(Theme.mono(11, .semibold))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(active ? Theme.amber.opacity(0.6) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct IconButton: View {
    let systemName: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(image)
                }
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("打开相册")
    }
}

// MARK: - 焦段

struct ZoomBar: View {
    let presets: [ZoomPreset]
    let selected: Int
    var vertical = false
    let onSelect: (Int) -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            ForEach(presets) { preset in
                let isOn = preset.id == selected
                Button {
                    onSelect(preset.id)
                } label: {
                    Text(preset.label)
                        .font(Theme.mono(isOn ? 12 : 11, .semibold))
                        .foregroundStyle(isOn ? Color.black : Color.white)
                        .frame(width: 38, height: 30)
                        .background(Capsule().fill(isOn ? Theme.amber : Color.white.opacity(0.08)))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

// MARK: - 胶片选择

struct LookSwatch: View {
    let look: FilmLook
    var selected: Bool
    var width: CGFloat = 52
    var height: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: look.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Theme.amber : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                // 胶片齿孔
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.35)).frame(width: 4, height: 3)
                    }
                }
                .padding(4)
            }
    }
}

struct LookStrip: View {
    let selectedID: String
    let onSelect: (FilmLook) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmLook.all) { look in
                        let isOn = look.id == selectedID
                        Button {
                            onSelect(look)
                        } label: {
                            VStack(spacing: 5) {
                                LookSwatch(look: look, selected: isOn)
                                Text(look.name)
                                    .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                                    .foregroundStyle(isOn ? Theme.amber : Theme.dim)
                            }
                        }
                        .buttonStyle(PressScaleStyle())
                        .id(look.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selectedID) { _, newValue in
                withAnimation(.snappy) { proxy.scrollTo(newValue, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
        }
    }
}

struct LookList: View {
    let selectedID: String
    let onSelect: (FilmLook) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(FilmLook.all) { look in
                        row(look)
                            .id(look.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedID) { _, newValue in
                withAnimation(.snappy) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func row(_ look: FilmLook) -> some View {
        let isOn = look.id == selectedID
        return Button {
            onSelect(look)
        } label: {
            HStack(spacing: 10) {
                LookSwatch(look: look, selected: isOn, width: 44, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(look.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isOn ? Theme.amber : .white)
                        Text(look.code)
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(Theme.dim)
                    }
                    Text(look.note)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Theme.amber.opacity(0.10) : Color.white.opacity(0.03))
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - 取景框装饰

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
    var length: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let inset: CGFloat = 10
            Path { p in
                p.move(to: CGPoint(x: inset, y: inset + length)); p.addLine(to: CGPoint(x: inset, y: inset)); p.addLine(to: CGPoint(x: inset + length, y: inset))
                p.move(to: CGPoint(x: w - inset - length, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset + length))
                p.move(to: CGPoint(x: inset, y: h - inset - length)); p.addLine(to: CGPoint(x: inset, y: h - inset)); p.addLine(to: CGPoint(x: inset + length, y: h - inset))
                p.move(to: CGPoint(x: w - inset - length, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset - length))
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
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

/// 曝光补偿刻度（竖直拖动取景框时出现）。
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
                        .position(x: geo.size.width / 2,
                                  y: geo.size.height * CGFloat((2 - value) / 4))
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
            Rectangle().frame(width: 34, height: 1)
            Spacer().frame(width: 18)
            Rectangle().frame(width: 34, height: 1)
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
