import SwiftUI

/// 取景器上的人像引导层：
/// - 虚线人形轮廓 = 主角应该在的位置和大小（目标框）
/// - 细白框 = 主角现在的位置，一条虚线把它连到目标框
/// - 越接近越亮（白 → 琥珀）；对准时目标框发光、闪星星、打勾
struct PortraitOverlay: View {
    let analysis: PortraitAnalysis
    let guidance: PortraitGuidance
    let geometry: ViewfinderGeometry

    var body: some View {
        let photo = geometry.photoRect
        ZStack {
            if let target = guidance.target.map({ toView($0, photo) }) {
                if let current = guidance.current.map({ toView($0, photo) }), !guidance.ready {
                    Connector(from: CGPoint(x: current.midX, y: current.midY),
                              to: CGPoint(x: target.midX, y: target.midY))
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.2)
                        .frame(width: max(current.width, 12), height: max(current.height, 12))
                        .position(x: current.midX, y: current.midY)
                }
                TargetGhost(kind: guidance.silhouette, score: guidance.score, ready: guidance.ready)
                    .frame(width: target.width, height: target.height)
                    .position(x: target.midX, y: target.midY)
                HintChip(guidance: guidance)
                    .position(x: min(max(target.midX, photo.minX + 90), photo.maxX - 90),
                              y: min(target.maxY + 30, photo.maxY - 24))
            } else if !guidance.hint.isEmpty {
                HintChip(guidance: guidance)
                    .position(x: photo.midX, y: photo.midY)
            }
            if let warning = guidance.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.35, blue: 0.25).opacity(0.85)))
                    .position(x: photo.midX, y: max(photo.minY, 0) + 64)
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: guidance)
    }

    private func toView(_ r: CGRect, _ photo: CGRect) -> CGRect {
        CGRect(x: photo.minX + r.minX * photo.width, y: photo.minY + r.minY * photo.height,
               width: r.width * photo.width, height: r.height * photo.height)
    }
}

struct Connector: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        // 箭头
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 9
        if hypot(to.x - from.x, to.y - from.y) > 24 {
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x - len * cos(angle - .pi / 7), y: to.y - len * sin(angle - .pi / 7)))
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x - len * cos(angle + .pi / 7), y: to.y - len * sin(angle + .pi / 7)))
        }
        return p
    }
}

/// 目标框：人形轮廓（头肩 / 全身），随接近程度变色，对准时发光 + 星星。
struct TargetGhost: View {
    let kind: PortraitGuidance.Silhouette
    let score: Double
    let ready: Bool
    @State private var pulse = false
    @State private var sparkle = false

    private var color: Color {
        ready ? Theme.amber : Color(red: 1, green: 1 - 0.36 * score, blue: 1 - 0.74 * score)
    }

    var body: some View {
        ZStack {
            outline
                .stroke(color, style: ready
                        ? StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                        : StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [6, 5]))
                .shadow(color: ready ? Theme.amber.opacity(0.9) : .clear, radius: ready ? 10 : 0)
                .shadow(color: ready ? Theme.amber.opacity(0.6) : .clear, radius: ready ? 22 : 0)
            if ready {
                outline
                    .fill(Theme.amber.opacity(pulse ? 0.16 : 0.04))
                Sparkles(animate: sparkle)
            }
        }
        .scaleEffect(ready && pulse ? 1.03 : 1)
        .onChange(of: ready) { _, isReady in
            if isReady {
                pulse = false
                sparkle = false
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                withAnimation(.easeOut(duration: 0.9)) { sparkle = true }
            } else {
                pulse = false
                sparkle = false
            }
        }
    }

    private var outline: SilhouetteShape { SilhouetteShape(kind: kind) }
}

/// 人形轮廓。head：rect 是脸框，额外画出肩膀；body：rect 是从头顶到脚的全身框。
struct SilhouetteShape: Shape {
    let kind: PortraitGuidance.Silhouette

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .none:
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 14, height: 14))
        case .head:
            // 头：比脸框略大的椭圆
            let head = r.insetBy(dx: -r.width * 0.12, dy: -r.height * 0.12)
            p.addEllipse(in: head)
            // 脖子 + 肩膀
            let neckTop = head.maxY - r.height * 0.02
            let shoulderY = r.maxY + r.height * 0.42
            let span = r.width * 1.55
            p.move(to: CGPoint(x: r.midX - r.width * 0.2, y: neckTop))
            p.addLine(to: CGPoint(x: r.midX - r.width * 0.22, y: shoulderY - r.height * 0.12))
            p.addQuadCurve(to: CGPoint(x: r.midX - span, y: shoulderY + r.height * 0.55),
                           control: CGPoint(x: r.midX - span * 0.95, y: shoulderY - r.height * 0.1))
            p.move(to: CGPoint(x: r.midX + r.width * 0.2, y: neckTop))
            p.addLine(to: CGPoint(x: r.midX + r.width * 0.22, y: shoulderY - r.height * 0.12))
            p.addQuadCurve(to: CGPoint(x: r.midX + span, y: shoulderY + r.height * 0.55),
                           control: CGPoint(x: r.midX + span * 0.95, y: shoulderY - r.height * 0.1))
        case .body:
            let h = r.height
            let headD = h * 0.13
            let cx = r.midX
            p.addEllipse(in: CGRect(x: cx - headD * 0.42, y: r.minY, width: headD * 0.84, height: headD))
            let shoulderY = r.minY + h * 0.17
            let hipY = r.minY + h * 0.52
            let sw = r.width * 0.5
            // 躯干
            p.move(to: CGPoint(x: cx - sw * 0.75, y: shoulderY))
            p.addLine(to: CGPoint(x: cx + sw * 0.75, y: shoulderY))
            p.addLine(to: CGPoint(x: cx + sw * 0.55, y: hipY))
            p.addLine(to: CGPoint(x: cx - sw * 0.55, y: hipY))
            p.closeSubpath()
            // 手臂
            p.move(to: CGPoint(x: cx - sw * 0.75, y: shoulderY))
            p.addLine(to: CGPoint(x: cx - sw * 0.95, y: r.minY + h * 0.48))
            p.move(to: CGPoint(x: cx + sw * 0.75, y: shoulderY))
            p.addLine(to: CGPoint(x: cx + sw * 0.95, y: r.minY + h * 0.48))
            // 腿
            p.move(to: CGPoint(x: cx - sw * 0.3, y: hipY))
            p.addLine(to: CGPoint(x: cx - sw * 0.38, y: r.maxY))
            p.move(to: CGPoint(x: cx + sw * 0.3, y: hipY))
            p.addLine(to: CGPoint(x: cx + sw * 0.38, y: r.maxY))
            // 脚底线（提示脚要放在这条线上）
            p.move(to: CGPoint(x: cx - sw * 0.9, y: r.maxY))
            p.addLine(to: CGPoint(x: cx + sw * 0.9, y: r.maxY))
        }
        return p
    }
}

struct Sparkles: View {
    let animate: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let spots: [(CGFloat, CGFloat, CGFloat)] = [
                (-0.08, 0.05, 14), (1.06, 0.12, 11), (0.95, -0.06, 9), (-0.04, 0.85, 10), (1.08, 0.78, 13), (0.5, -0.12, 10),
            ]
            ForEach(0..<spots.count, id: \.self) { i in
                let s = spots[i]
                Image(systemName: "sparkle")
                    .font(.system(size: s.2, weight: .bold))
                    .foregroundStyle(Theme.amber)
                    .shadow(color: Theme.amber, radius: 4)
                    .position(x: w * s.0, y: h * s.1)
                    .scaleEffect(animate ? 1 : 0.2)
                    .opacity(animate ? 1 : 0)
                    .rotationEffect(.degrees(animate ? 0 : -60))
            }
        }
    }
}

struct HintChip: View {
    let guidance: PortraitGuidance

    var body: some View {
        HStack(spacing: 6) {
            if guidance.ready {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.amber)
            } else {
                ProgressRingSmall(value: guidance.score)
            }
            Text(guidance.hint)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(.black.opacity(0.5)))
        .overlay(Capsule().strokeBorder(guidance.ready ? Theme.amber : .clear, lineWidth: 1))
    }
}

/// 小圆环：显示与目标的接近程度。
struct ProgressRingSmall: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, value))
                .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

/// 姿势建议卡片。
struct PoseCard: View {
    let pose: PoseIdea?
    let tip: String
    let onNext: () -> Void

    var body: some View {
        if let pose {
            HStack(spacing: 10) {
                Image(systemName: pose.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("姿势 · \(pose.title)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(pose.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                    if !tip.isEmpty {
                        Text(tip)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.amber.opacity(0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onNext) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("换一个姿势")
            }
            .padding(10)
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(pose.id)
        }
    }
}

/// 胶片 / 人像 模式切换。
struct ModeSwitch: View {
    @Binding var modeRaw: String

    var body: some View {
        HStack(spacing: 18) {
            item("胶片", "film")
            item("人像", "portrait")
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private func item(_ title: String, _ value: String) -> some View {
        let on = modeRaw == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) { modeRaw = value }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? Theme.amber : Color.white.opacity(0.75))
                Circle()
                    .fill(on ? Theme.amber : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(minWidth: 44, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
