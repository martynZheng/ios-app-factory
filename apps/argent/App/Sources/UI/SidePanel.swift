import SwiftUI

/// 右侧侧边栏：所有设置都在这里，主界面保持干净。
struct SidePanel: View {
    @Binding var lookID: String
    @Binding var aspectRaw: String
    @Binding var grainRaw: String
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Binding var keepOriginal: Bool
    @Binding var watermarkOn: Bool
    @Binding var watermarkText: String
    @Binding var modeRaw: String
    @Binding var skinRaw: String
    @Binding var beautyRaw: String
    @Binding var showPoses: Bool
    @Binding var showGuide: Bool
    @Binding var templateChoice: String
    let autoTemplateName: String

    let zoomPresets: [ZoomPreset]
    let zoomIndex: Int
    let isFront: Bool
    let onZoom: (Int) -> Void
    let onFlip: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    section("模式") {
                        OptionChips(options: ["胶片", "人像"], selected: modeRaw == "portrait" ? "人像" : "胶片") {
                            modeRaw = $0 == "人像" ? "portrait" : "film"
                        }
                    }
                    if modeRaw == "portrait" {
                        portraitSection
                    } else {
                        filmSection
                    }
                    section("焦段") {
                        OptionChips(options: zoomPresets.map { $0.focal },
                                    selected: zoomPresets.indices.contains(zoomIndex) ? zoomPresets[zoomIndex].focal : "") { focal in
                            if let preset = zoomPresets.first(where: { $0.focal == focal }) { onZoom(preset.id) }
                        }
                    }
                    section("画幅") {
                        OptionChips(options: AspectRatio.allCases.map { $0.rawValue }, selected: aspectRaw) { aspectRaw = $0 }
                    }
                    section("颗粒") {
                        OptionChips(options: GrainLevel.allCases.map { $0.rawValue }, selected: grainRaw) { grainRaw = $0 }
                    }
                    watermarkSection
                    section("取景") {
                        VStack(spacing: 0) {
                            PanelToggle(title: "九宫格", isOn: $showGrid)
                            PanelToggle(title: "水平仪", isOn: $showLevel)
                            PanelToggle(title: "同时保存原图", isOn: $keepOriginal)
                        }
                    }
                    section("镜头") {
                        Button(action: onFlip) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                Text(isFront ? "切换到后置镜头" : "切换到前置镜头")
                                Spacer()
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    gestureGuide
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
                .ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            Text("银盐")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var filmSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(FilmLook.Family.film, id: \.self) { family in
                section(family.rawValue) {
                    VStack(spacing: 6) {
                        ForEach(FilmLook.all.filter { $0.family == family }) { look in
                            LookRow(look: look, selected: look.id == lookID) { lookID = look.id }
                        }
                    }
                }
            }
        }
    }

    private var portraitSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("肤色") {
                VStack(alignment: .leading, spacing: 8) {
                    OptionChips(options: SkinTone.allCases.map { $0.rawValue }, selected: skinRaw) { skinRaw = $0 }
                    Text(skinHint)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            }
            section("美颜") {
                VStack(alignment: .leading, spacing: 8) {
                    OptionChips(options: BeautyLevel.allCases.map { $0.rawValue }, selected: beautyRaw) { beautyRaw = $0 }
                    Text("只磨肤色区域并保留皮肤纹理，像本人但更好看")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            }
            section("场景模板") {
                VStack(alignment: .leading, spacing: 8) {
                    TemplateCell(title: "自动", subtitle: "当前识别：\(autoTemplateName)", selected: templateChoice == "auto") {
                        templateChoice = "auto"
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(PortraitLibrary.templates) { t in
                            TemplateCell(title: t.name, subtitle: t.note, selected: templateChoice == t.id) {
                                templateChoice = t.id
                            }
                        }
                    }
                }
            }
            section("引导") {
                VStack(spacing: 0) {
                    PanelToggle(title: "构图引导", isOn: $showGuide)
                    PanelToggle(title: "姿势建议", isOn: $showPoses)
                }
            }
        }
    }

    private var skinHint: String {
        switch SkinTone(rawValue: skinRaw) ?? .smart {
        case .smart: return "根据画面里测到的肤色自动提亮、去黄、加气色"
        case .natural: return "轻微提亮，保持本来的肤色"
        case .fair: return "冷白通透，去掉皮肤黄气"
        case .peach: return "粉嫩好气色，甜妹感"
        case .warm: return "暖调健康，适合秋冬和室内"
        case .tan: return "保留小麦色的健康光泽"
        }
    }

    private var watermarkSection: some View {
        section("水印") {
            VStack(alignment: .leading, spacing: 10) {
                PanelToggle(title: "在照片上添加水印", isOn: $watermarkOn)
                if watermarkOn {
                    TextField("水印文字", text: $watermarkText)
                        .font(.custom(Watermark.fontName, size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                    Text("显示在照片右下角，取景时可预览")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            }
            .animation(.snappy(duration: 0.2), value: watermarkOn)
        }
    }

    private var gestureGuide: some View {
        section("手势") {
            VStack(alignment: .leading, spacing: 8) {
                Label("左右滑动画面 · 换胶片", systemImage: "arrow.left.and.right")
                Label("上下滑动画面 · 曝光补偿", systemImage: "arrow.up.and.down")
                Label("轻点画面 · 对焦测光", systemImage: "scope")
                Label("音量键 / 相机控制 · 快门", systemImage: "camera.shutter.button")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.dim)
            content()
        }
    }
}

struct LookRow: View {
    let look: FilmLook
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LookSwatch(look: look, selected: selected, width: 42, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(look.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Theme.amber : .white)
                    Text(look.note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.amber.opacity(0.12) : Color.white.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct OptionChips: View {
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selected
                Button {
                    onSelect(option)
                } label: {
                    Text(option)
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(isOn ? Color.black : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isOn ? Theme.amber : Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .tint(Theme.amber)
        .frame(height: 40)
    }
}

struct TemplateCell: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Theme.amber : .white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.amber.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.amber.opacity(0.7) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}
