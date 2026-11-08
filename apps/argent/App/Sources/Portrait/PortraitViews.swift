import SwiftUI

/// 取景器上的人像引导层：人脸框、目标点、一句话提示。
struct PortraitOverlay: View {
    let analysis: PortraitAnalysis
    let guidance: PortraitGuidance
    let geometry: ViewfinderGeometry

    var body: some View {
        let photo = geometry.photoRect
        ZStack {
            ForEach(Array(analysis.faces.prefix(6).enumerated()), id: \.offset) { index, face in
                faceBox(face, primary: index == 0)
            }
            if let target = guidance.targetInPhoto, !guidance.ready {
                TargetMarker()
                    .position(x: photo.minX + target.x * photo.width, y: photo.minY + target.y * photo.height)
            }
            GuidanceCapsule(guidance: guidance)
                .position(x: photo.midX, y: max(photo.minY, 0) + 64)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: guidance)
    }

    private func faceBox(_ face: CGRect, primary: Bool) -> some View {
        let r = geometry.viewRect(fromNormalized: face)
        let color: Color = primary ? (guidance.ready ? Theme.amber : Color.white.opacity(0.85)) : Color.white.opacity(0.35)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(color, lineWidth: primary ? 1.4 : 1)
            .frame(width: max(r.width, 10), height: max(r.height, 10))
            .position(x: r.midX, y: r.midY)
            .animation(.easeOut(duration: 0.25), value: r)
    }
}

struct TargetMarker: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.amber.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Theme.amber)
                .frame(width: 6, height: 6)
        }
        .scaleEffect(pulse ? 1.12 : 0.92)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct GuidanceCapsule: View {
    let guidance: PortraitGuidance

    private var symbol: String {
        if guidance.ready { return "checkmark.circle.fill" }
        switch guidance.arrow {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .back: return "arrow.down.right.and.arrow.up.left"
        case .lower: return "arrow.down.to.line"
        case .none: return "person.crop.rectangle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(guidance.ready ? Theme.amber : .white)
            Text(guidance.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(guidance.ready ? Theme.amber.opacity(0.8) : .clear, lineWidth: 1))
        .padding(.horizontal, 16)
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
