import SwiftUI

/// 主界面。根据可用空间自动切换两套布局：
/// - 竖向（iPhone Duo 外屏竖握 / 普通 iPhone 竖握 / 内屏竖握）：顶栏 + 取景 + 焦段 + 胶片条 + 快门行
/// - 横向（iPhone Duo 展开的内屏、任何横握）：左侧工具栏 + 取景 + 右侧“机身”控制区；
///   内屏为 regular 尺寸类别时，右侧展开为带说明的胶片列表。
struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var level = LevelMotion()

    @AppStorage("look") private var lookID = FilmLook.all[0].id
    @AppStorage("aspect") private var aspectRaw = AspectRatio.r3x2.rawValue
    @AppStorage("grain") private var grainRaw = GrainLevel.standard.rawValue
    @AppStorage("grid") private var showGrid = false
    @AppStorage("level") private var showLevel = true
    @AppStorage("keepOriginal") private var keepOriginal = false

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var flash = false
    @State private var toast: FilmLook?
    @State private var toastToken = 0
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var dragAxis: Axis?
    @State private var dragStartEV: Float = 0
    @State private var showEV = false
    @State private var showSettings = false
    @State private var shotCount = 0

    private var look: FilmLook { FilmLook.find(lookID) }
    private var aspect: AspectRatio { AspectRatio(rawValue: aspectRaw) ?? .r3x2 }
    private var grain: GrainLevel { GrainLevel(rawValue: grainRaw) ?? .standard }
    private var roomy: Bool { hSize == .regular && vSize == .regular }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.05
            ZStack {
                Theme.ink.ignoresSafeArea()
                if wide {
                    wideLayout(size: geo.size)
                } else {
                    tallLayout(size: geo.size)
                }
                RotationAnchor(layer: camera.anchorLayer)
                    .frame(width: 2, height: 2)
                    .allowsHitTesting(false)
                overlays
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .modifier(HardwareShutter { shoot() })
        .sensoryFeedback(.selection, trigger: lookID)
        .sensoryFeedback(.impact(weight: .medium), trigger: shotCount)
        .onAppear {
            camera.start()
            level.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.start()
                level.start()
            case .background:
                camera.stop()
                level.stop()
            default:
                break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(aspectRaw: $aspectRaw, grainRaw: $grainRaw, showGrid: $showGrid,
                          showLevel: $showLevel, keepOriginal: $keepOriginal)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("好", role: .cancel) { camera.message = nil }
        } message: {
            Text(camera.message ?? "")
        }
    }

    // MARK: - 竖向布局

    private func tallLayout(size: CGSize) -> some View {
        let compactHeight = size.height < 760
        return VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)

            viewfinderArea(landscape: false)
                .padding(.horizontal, roomy ? 24 : 8)

            ZoomBar(presets: camera.zoomPresets, selected: camera.zoomIndex) { camera.selectZoom($0) }
                .padding(.top, 10)

            LookStrip(selectedID: lookID) { select($0) }
                .frame(height: 62)
                .padding(.top, compactHeight ? 8 : 14)

            HStack {
                ThumbnailButton(image: camera.lastThumbnail)
                Spacer()
                ShutterButton(size: compactHeight ? 68 : 78, busy: camera.processingCount > 0) { shoot() }
                Spacer()
                IconButton(systemName: "arrow.triangle.2.circlepath") { camera.switchCamera() }
            }
            .padding(.horizontal, 30)
            .padding(.top, compactHeight ? 6 : 12)
            .padding(.bottom, compactHeight ? 6 : 14)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ChipButton(title: aspect.rawValue, active: true) { cycleAspect() }
            ChipButton(title: "颗粒", value: grain.rawValue, active: grain != .off) { grainRaw = grain.next.rawValue }
            ChipButton(title: "EV", value: evText, active: camera.exposureBias != 0) { camera.setExposureBias(0) }
            Spacer(minLength: 0)
            IconButton(systemName: "slider.horizontal.3", size: 34) { showSettings = true }
        }
    }

    // MARK: - 横向布局

    private func wideLayout(size: CGSize) -> some View {
        let panelWidth: CGFloat = roomy ? min(300, size.width * 0.3) : 118
        return HStack(spacing: 0) {
            sideRail
                .frame(width: 64)

            viewfinderArea(landscape: true)
                .padding(.vertical, 10)

            Group {
                if roomy {
                    roomyPanel
                } else {
                    compactPanel
                }
            }
            .frame(width: panelWidth)
            .padding(.vertical, 10)
            .padding(.trailing, 10)
        }
    }

    private var sideRail: some View {
        VStack(spacing: 10) {
            IconButton(systemName: "slider.horizontal.3", size: 36) { showSettings = true }
            Spacer()
            ChipButton(title: aspect.rawValue, active: true) { cycleAspect() }
            ChipButton(title: grain.rawValue, active: grain != .off) { grainRaw = grain.next.rawValue }
            ChipButton(title: evText, active: camera.exposureBias != 0) { camera.setExposureBias(0) }
            Spacer()
        }
        .padding(.vertical, 14)
    }

    /// 内屏（regular × regular）：右侧是完整的“机身”区——胶片列表 + 焦段 + 快门。
    private var roomyPanel: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FILM")
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.dim)
                LookList(selectedID: lookID) { select($0) }
            }
            .frame(maxHeight: .infinity)

            ZoomBar(presets: camera.zoomPresets, selected: camera.zoomIndex) { camera.selectZoom($0) }

            HStack {
                ThumbnailButton(image: camera.lastThumbnail, size: 50)
                Spacer()
                ShutterButton(size: 84, busy: camera.processingCount > 0) { shoot() }
                Spacer()
                IconButton(systemName: "arrow.triangle.2.circlepath") { camera.switchCamera() }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    /// 外屏横握 / 普通 iPhone 横握：紧凑的竖排控制。
    private var compactPanel: some View {
        VStack(spacing: 10) {
            ThumbnailButton(image: camera.lastThumbnail)
            Spacer(minLength: 4)
            lookStepper
            Spacer(minLength: 4)
            ShutterButton(size: 70, busy: camera.processingCount > 0) { shoot() }
            Spacer(minLength: 4)
            ZoomBar(presets: camera.zoomPresets, selected: camera.zoomIndex, vertical: true) { camera.selectZoom($0) }
                .scaleEffect(0.9)
            IconButton(systemName: "arrow.triangle.2.circlepath", size: 38) { camera.switchCamera() }
        }
    }

    private var lookStepper: some View {
        VStack(spacing: 6) {
            Button { stepLook(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
            }
            LookSwatch(look: look, selected: true, width: 46, height: 30)
            Text(look.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Button { stepLook(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - 取景区

    private func viewfinderArea(landscape: Bool) -> some View {
        GeometryReader { geo in
            let ratio = aspect.widthOverHeight(landscape: landscape)
            let fitted = fit(ratio: ratio, in: geo.size)
            viewfinder(size: fitted)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .animation(.snappy(duration: 0.28), value: aspectRaw)
        }
    }

    private func fit(ratio: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > ratio {
            return CGSize(width: size.height * ratio, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / ratio)
    }

    private func viewfinder(size: CGSize) -> some View {
        ZStack {
            Color.black
            if camera.status == .running || camera.status == .idle {
                FilmViewfinder(frames: camera.frames, look: look, grainScale: grain.scale)
            }
            if showGrid { GridOverlay() }
            FrameCorners()
            if showLevel && !level.isFlat {
                LevelLine(tilt: level.tilt)
            }
            if let focusPoint {
                FocusReticle()
                    .id(focusToken)
                    .position(focusPoint)
            }
            if showEV {
                HStack {
                    Spacer()
                    ExposureScale(value: camera.exposureBias)
                        .padding(.trailing, 12)
                }
                .transition(.opacity)
            }
            if let toast {
                VStack(spacing: 4) {
                    Text(toast.name)
                        .font(.system(size: 30, weight: .semibold))
                    Text(toast.note)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.45)))
                .padding(24)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
            }
            infoLine
            Color.black
                .opacity(flash ? 1 : 0)
                .allowsHitTesting(false)
            statusOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                focus(at: value.location, size: size)
            }
        )
    }

    private var infoLine: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(look.code).foregroundStyle(Theme.amber)
                if camera.zoomPresets.indices.contains(camera.zoomIndex) {
                    Text(camera.zoomPresets[camera.zoomIndex].focal)
                }
                Text(aspect.rawValue)
                if camera.exposureBias != 0 { Text(evText) }
                Spacer()
            }
            .font(Theme.mono(10, .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .shadow(color: .black.opacity(0.6), radius: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            VStack(spacing: 12) {
                Image(systemName: "camera.aperture").font(.system(size: 34))
                Text("需要相机权限").font(.headline)
                Text("在设置中允许「银盐」使用相机").font(.footnote).foregroundStyle(Theme.dim)
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
            }
            .padding()
        case .failed:
            Text("相机启动失败").font(.headline).foregroundStyle(Theme.dim)
        default:
            if camera.isInterrupted {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 26))
                    Text("相机暂不可用").font(.headline)
                    Text("分屏或其他 App 正在使用相机").font(.footnote).foregroundStyle(Theme.dim)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.6)))
            }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        EmptyView()
    }

    // MARK: - 手势

    /// 竖直拖动：曝光补偿（1/3 档步进，像拨盘）；水平滑动：切换胶片。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.height) > abs(value.translation.width) ? .vertical : .horizontal
                    dragStartEV = camera.exposureBias
                    if dragAxis == .vertical {
                        withAnimation(.easeOut(duration: 0.15)) { showEV = true }
                    }
                }
                if dragAxis == .vertical {
                    let raw = dragStartEV - Float(value.translation.height / 60)
                    let stepped = (raw * 3).rounded() / 3
                    let clamped = min(max(stepped, -2), 2)
                    if clamped != camera.exposureBias { camera.setExposureBias(clamped) }
                }
            }
            .onEnded { value in
                if dragAxis == .horizontal, abs(value.translation.width) > 50 {
                    stepLook(value.translation.width < 0 ? 1 : -1)
                }
                dragAxis = nil
                withAnimation(.easeOut(duration: 0.4).delay(0.6)) { showEV = false }
            }
    }

    // MARK: - Actions

    private var evText: String {
        camera.exposureBias == 0 ? "±0" : String(format: "%+.1f", camera.exposureBias)
    }

    private func cycleAspect() {
        aspectRaw = aspect.next.rawValue
    }

    private func select(_ newLook: FilmLook) {
        guard newLook.id != lookID else { return }
        lookID = newLook.id
        showToast(newLook)
    }

    private func stepLook(_ delta: Int) {
        let all = FilmLook.all
        guard let index = all.firstIndex(where: { $0.id == lookID }) else { return }
        let next = (index + delta + all.count) % all.count
        select(all[next])
    }

    private func showToast(_ newLook: FilmLook) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { toast = newLook }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if token == toastToken {
                withAnimation(.easeIn(duration: 0.3)) { toast = nil }
            }
        }
    }

    private func focus(at point: CGPoint, size: CGSize) {
        camera.focus(at: point, in: size)
        focusToken += 1
        let token = focusToken
        focusPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if token == focusToken {
                withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
            }
        }
    }

    private func shoot() {
        guard camera.status == .running else { return }
        shotCount += 1
        flash = true
        withAnimation(.easeOut(duration: 0.28)) { flash = false }
        camera.capture(look: look, aspect: aspect, grainScale: grain.scale, keepOriginal: keepOriginal)
    }
}

// MARK: - 设置

struct SettingsSheet: View {
    @Binding var aspectRaw: String
    @Binding var grainRaw: String
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Binding var keepOriginal: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("画面") {
                    Picker("画幅", selection: $aspectRaw) {
                        ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Picker("颗粒", selection: $grainRaw) {
                        ForEach(GrainLevel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                Section("取景") {
                    Toggle("九宫格", isOn: $showGrid)
                    Toggle("水平仪", isOn: $showLevel)
                }
                Section {
                    Toggle("同时保存原图", isOn: $keepOriginal)
                } footer: {
                    Text("开启后每次拍摄会额外保存一张未加胶片效果的原图。")
                }
                Section("操作") {
                    Label("上下拖动取景框：曝光补偿", systemImage: "plusminus")
                    Label("左右滑动取景框：切换胶片", systemImage: "film")
                    Label("轻点取景框：对焦与测光", systemImage: "scope")
                    Label("音量键 / 相机控制：快门", systemImage: "button.horizontal.top.press")
                }
                Section("胶片") {
                    ForEach(FilmLook.all) { look in
                        HStack(spacing: 12) {
                            LookSwatch(look: look, selected: false, width: 40, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.name).font(.subheadline.weight(.semibold))
                                Text(look.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("银盐")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.amber)
    }
}
