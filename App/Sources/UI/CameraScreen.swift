import SwiftUI

/// 主界面：取景铺满全屏，只留下拍照必需的四样东西——快门、焦段、相册、菜单。
/// 其余所有设置（胶片、画幅、颗粒、水印……）都在右侧侧边栏里。
/// 竖屏（iPhone Duo 外屏）控制在底部；横屏（Duo 内屏展开 / 横握）控制在右侧，像握着一台相机。
struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @StateObject private var level = LevelMotion()

    @AppStorage("look") private var lookID = FilmLook.all[0].id
    @AppStorage("aspect") private var aspectRaw = AspectRatio.r3x2.rawValue
    @AppStorage("grain") private var grainRaw = GrainLevel.standard.rawValue
    @AppStorage("grid") private var showGrid = false
    @AppStorage("level") private var showLevel = true
    @AppStorage("keepOriginal") private var keepOriginal = false
    @AppStorage("watermarkOn") private var watermarkOn = false
    @AppStorage("watermarkText") private var watermarkText = "Photographed by Claude"
    @AppStorage("hintSeen") private var hintSeen = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var showPanel = false
    @State private var flash = false
    @State private var toast: FilmLook?
    @State private var toastToken = 0
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var dragAxis: Axis?
    @State private var dragStartEV: Float = 0
    @State private var showEV = false
    @State private var shotCount = 0

    private var look: FilmLook { FilmLook.find(lookID) }
    private var aspect: AspectRatio { AspectRatio(rawValue: aspectRaw) ?? .r3x2 }
    private var grain: GrainLevel { GrainLevel(rawValue: grainRaw) ?? .standard }
    private var activeWatermark: String? {
        let text = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return watermarkOn && !text.isEmpty ? text : nil
    }

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            viewfinderLayer
                .ignoresSafeArea()
            controlsLayer
            if !hintSeen && camera.status == .running {
                hint
            }
            panelLayer
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
        .alert("提示", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("好", role: .cancel) { camera.message = nil }
        } message: {
            Text(camera.message ?? "")
        }
    }

    // MARK: - 取景层（全屏）

    private var viewfinderLayer: some View {
        GeometryReader { geo in
            let geometry = ViewfinderGeometry(frameSize: camera.frameSize, viewSize: geo.size, aspect: aspect)
            let photo = geometry.photoRect
            ZStack {
                Color.black
                if camera.status == .running || camera.status == .idle {
                    FilmViewfinder(frames: camera.frames, look: look, grainScale: grain.scale, aspect: aspect)
                }
                ViewfinderMask(photoRect: photo)
                photoDecorations
                    .frame(width: photo.width, height: photo.height)
                    .position(x: photo.midX, y: photo.midY)
                if let focusPoint {
                    FocusReticle()
                        .id(focusToken)
                        .position(focusPoint)
                }
                if showEV {
                    ExposureScale(value: camera.exposureBias)
                        .position(x: min(photo.maxX, geo.size.width) - 40, y: photo.midY)
                        .transition(.opacity)
                }
                if let toast {
                    toastView(toast)
                        .position(x: photo.midX, y: photo.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Color.black
                    .opacity(flash ? 1 : 0)
                    .allowsHitTesting(false)
                statusOverlay
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    focus(at: value.location, geometry: geometry)
                }
            )
            .animation(.snappy(duration: 0.28), value: aspectRaw)
        }
    }

    private var photoDecorations: some View {
        ZStack {
            if showGrid { GridOverlay() }
            FrameCorners()
            if showLevel && !level.isFlat {
                LevelLine(tilt: level.tilt)
            }
            if let activeWatermark {
                WatermarkPreview(text: activeWatermark)
            }
        }
        .allowsHitTesting(false)
    }

    private func toastView(_ film: FilmLook) -> some View {
        VStack(spacing: 4) {
            Text(film.name)
                .font(.system(size: 28, weight: .semibold))
            Text(film.family.rawValue)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.amber)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.4)))
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

    // MARK: - 控制层（避开安全区）

    private var controlsLayer: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                wideControls
            } else {
                tallControls
            }
        }
    }

    private var hud: some View {
        HStack(spacing: 8) {
            Text(look.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(aspect.rawValue)
            if camera.exposureBias != 0 {
                Button {
                    camera.setExposureBias(0)
                } label: {
                    Text(String(format: "%+.1f EV", camera.exposureBias))
                        .foregroundStyle(Theme.amber)
                }
            }
            if activeWatermark != nil {
                Image(systemName: "signature")
            }
        }
        .font(Theme.mono(11, .medium))
        .foregroundStyle(Color.white.opacity(0.7))
        .shadow(color: .black.opacity(0.7), radius: 3)
    }

    private var tallControls: some View {
        VStack(spacing: 0) {
            HStack {
                hud
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            FocalSelector(presets: camera.zoomPresets, selected: camera.zoomIndex) { camera.selectZoom($0) }
                .padding(.bottom, 14)

            HStack {
                ThumbnailButton(image: camera.lastThumbnail)
                Spacer()
                ShutterButton(busy: camera.processingCount > 0) { shoot() }
                Spacer()
                GlassButton(systemName: "line.3.horizontal") { openPanel() }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)
        }
    }

    private var wideControls: some View {
        HStack(spacing: 0) {
            VStack {
                hud
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 0) {
                GlassButton(systemName: "line.3.horizontal") { openPanel() }
                Spacer()
                FocalSelector(presets: camera.zoomPresets, selected: camera.zoomIndex, vertical: true) { camera.selectZoom($0) }
                    .padding(.bottom, 16)
                ShutterButton(size: 78, busy: camera.processingCount > 0) { shoot() }
                Spacer()
                ThumbnailButton(image: camera.lastThumbnail)
            }
            .padding(.vertical, 16)
            .padding(.trailing, 22)
        }
    }

    // MARK: - 首次使用提示

    private var hint: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Label("左右滑动 换胶片", systemImage: "arrow.left.and.right")
                Label("上下滑动 调曝光", systemImage: "arrow.up.and.down")
                Label("轻点画面 对焦", systemImage: "scope")
                Button("知道了") {
                    withAnimation { hintSeen = true }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .padding(.top, 4)
            }
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
            Spacer()
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - 侧边栏

    private var panelLayer: some View {
        GeometryReader { geo in
            let width = min(360, geo.size.width * 0.84)
            ZStack(alignment: .trailing) {
                if showPanel {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { closePanel() }
                        .transition(.opacity)
                    SidePanel(
                        lookID: $lookID,
                        aspectRaw: $aspectRaw,
                        grainRaw: $grainRaw,
                        showGrid: $showGrid,
                        showLevel: $showLevel,
                        keepOriginal: $keepOriginal,
                        watermarkOn: $watermarkOn,
                        watermarkText: $watermarkText,
                        zoomPresets: camera.zoomPresets,
                        zoomIndex: camera.zoomIndex,
                        isFront: camera.position == .front,
                        onZoom: { camera.selectZoom($0) },
                        onFlip: { camera.switchCamera() },
                        onClose: { closePanel() }
                    )
                    .frame(width: width)
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(showPanel)
    }

    private func openPanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { showPanel = true }
    }

    private func closePanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { showPanel = false }
    }

    // MARK: - 手势

    /// 竖直拖动：曝光补偿（1/3 档步进，像拨盘）；水平滑动：切换胶片。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
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
                if !hintSeen { withAnimation { hintSeen = true } }
            }
    }

    // MARK: - Actions

    private func stepLook(_ delta: Int) {
        let all = FilmLook.all
        guard let index = all.firstIndex(where: { $0.id == lookID }) else { return }
        let next = all[(index + delta + all.count) % all.count]
        lookID = next.id
        showToast(next)
    }

    private func showToast(_ newLook: FilmLook) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { toast = newLook }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if token == toastToken {
                withAnimation(.easeIn(duration: 0.3)) { toast = nil }
            }
        }
    }

    private func focus(at point: CGPoint, geometry: ViewfinderGeometry) {
        camera.focus(normalized: geometry.normalizedFramePoint(point))
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
        if showPanel { closePanel() }
        shotCount += 1
        flash = true
        withAnimation(.easeOut(duration: 0.28)) { flash = false }
        camera.capture(look: look, aspect: aspect, grainScale: grain.scale,
                       keepOriginal: keepOriginal, watermark: activeWatermark)
    }
}
