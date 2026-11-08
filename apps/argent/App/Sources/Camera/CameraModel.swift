import AVFoundation
import CoreImage
import UIKit

/// 最新一帧取景画面（视频队列写、渲染线程读）。
final class FrameBuffer {
    private let lock = NSLock()
    private var image: CIImage?

    func set(_ newImage: CIImage) {
        lock.lock()
        image = newImage
        lock.unlock()
    }

    func get() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }
}

struct ZoomPreset: Identifiable, Equatable {
    let id: Int
    let label: String
    let focal: String     // 等效焦距说明
    let factor: CGFloat
}

/// 相机：AVCaptureSession + 自绘取景（视频帧）+ 拍照。
/// 方向用 RotationCoordinator 处理——iPhone Duo 内屏/外屏、横竖持握下都能得到正确的取景和成片方向。
final class CameraModel: NSObject, ObservableObject {
    enum Status { case idle, unauthorized, failed, running }

    @Published var status: Status = .idle
    @Published var position: AVCaptureDevice.Position = .back
    @Published var zoomPresets: [ZoomPreset] = []
    @Published var zoomIndex = 0
    @Published var exposureBias: Float = 0
    @Published var lastThumbnail: UIImage?
    @Published var isInterrupted = false
    @Published var processingCount = 0
    @Published var message: String?
    /// 当前取景帧（已转正）的像素尺寸，用来计算取景框。
    @Published var frameSize: CGSize = CGSize(width: 3, height: 4)

    let session = AVCaptureSession()
    let frames = FrameBuffer()

    /// 不可见的预览层，只用来让 RotationCoordinator 知道界面方向。
    lazy var anchorLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private(set) var previewAngle: CGFloat = 90

    private let sessionQueue = DispatchQueue(label: "argent.camera.session")
    private let videoQueue = DispatchQueue(label: "argent.camera.video", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "argent.camera.processing", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let photoContext = CIContext(options: [.cacheIntermediates: false])

    private var input: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var configured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    private struct PendingCapture {
        let look: FilmLook
        let aspect: AspectRatio
        let grainScale: Float
        let keepOriginal: Bool
        let watermark: String?
        let portrait: PortraitOptions?
    }

    private var lastFrameSize: CGSize = .zero
    private var pending: [Int64: PendingCapture] = [:]
    private let pendingLock = NSLock()

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.isInterrupted = true
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.isInterrupted = false
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.restartSession()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configureAndRun() } else { self.status = .unauthorized }
                }
            }
        default:
            status = .unauthorized
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func restartSession() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            if !self.configured {
                self.configureSession(position: .back)
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.status = running ? .running : .failed
                self.setupRotation()
            }
        }
    }

    // MARK: - Configuration (sessionQueue)

    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        return discovery.devices.first
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        guard let device = Self.bestDevice(for: position),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }

        if let old = input { session.removeInput(old) }
        guard session.canAddInput(newInput) else {
            if let old = input, session.canAddInput(old) { session.addInput(old) }
            return
        }
        session.addInput(newInput)
        input = newInput
        currentDevice = device

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }
        if !session.outputs.contains(photoOutput) {
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = true
        }

        // 成片分辨率：不超过约 24MP（接近 GR 的 2400 万像素），兼顾画质与冲洗速度。
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let fitting = dims.filter { Int($0.width) * Int($0.height) <= 26_000_000 }
        let best = fitting.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) } ?? dims.first
        if let best { photoOutput.maxPhotoDimensions = best }

        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }

        configureZoom(device)
        applyExposureBias(exposureBiasSnapshot, to: device)
    }

    private var exposureBiasSnapshot: Float = 0

    private func configureZoom(_ device: AVCaptureDevice) {
        // 双摄虚拟设备：zoomFactor 1 = 超广角，切换点 = 主摄（1×）。
        var main: CGFloat = 1
        if device.isVirtualDevice,
           device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            main = CGFloat(truncating: first)
        }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, main * 10)

        // 等效焦距按主摄 24mm 估算。28 / 40 对应 GR 与 GR x 的视角。
        let candidates: [(String, String, CGFloat)] = [
            ("0.5×", "13mm", 0.5),
            ("1×", "24mm", 1),
            ("28", "28mm", 28.0 / 24.0),
            ("40", "40mm", 40.0 / 24.0),
            ("2×", "48mm", 2),
        ]
        var presets: [ZoomPreset] = []
        for (label, focal, relative) in candidates {
            let factor = main * relative
            if factor >= minZoom - 0.001 && factor <= maxZoom {
                presets.append(ZoomPreset(id: presets.count, label: label, focal: focal, factor: factor))
            }
        }
        let defaultIndex = presets.firstIndex(where: { $0.label == "28" })
            ?? presets.firstIndex(where: { $0.label == "1×" }) ?? 0
        if presets.indices.contains(defaultIndex) {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = presets[defaultIndex].factor
                device.unlockForConfiguration()
            } catch {}
        }
        DispatchQueue.main.async {
            self.zoomPresets = presets
            self.zoomIndex = defaultIndex
        }
    }

    private func applyExposureBias(_ bias: Float, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let value = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(value, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - Rotation (main)

    private func setupRotation() {
        guard let device = currentDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: anchorLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            guard let self else { return }
            DispatchQueue.main.async { self.previewAngle = angle }
            self.sessionQueue.async {
                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    // MARK: - 测光数据（人像模式判断光线）

    func lightMetrics() -> LightMetrics {
        guard let device = currentDevice else { return LightMetrics(ev100: 10, kelvin: 5500) }
        let iso = Double(max(device.iso, 1))
        let seconds = max(CMTimeGetSeconds(device.exposureDuration), 1e-5)
        let aperture = Double(max(device.lensAperture, 1))
        let ev100 = log2(aperture * aperture / seconds) - log2(iso / 100)
        var kelvin = 5500.0
        let gains = device.deviceWhiteBalanceGains
        if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1 {
            let clamped = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(gains.redGain, device.maxWhiteBalanceGain),
                greenGain: min(gains.greenGain, device.maxWhiteBalanceGain),
                blueGain: min(gains.blueGain, device.maxWhiteBalanceGain))
            kelvin = Double(device.temperatureAndTintValues(for: clamped).temperature)
        }
        return LightMetrics(ev100: ev100, kelvin: kelvin)
    }

    // MARK: - Controls

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        sessionQueue.async {
            self.configureSession(position: newPosition)
            DispatchQueue.main.async {
                self.position = newPosition
                self.setupRotation()
            }
        }
    }

    func selectZoom(_ index: Int) {
        guard zoomPresets.indices.contains(index) else { return }
        zoomIndex = index
        let factor = zoomPresets[index].factor
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.ramp(toVideoZoomFactor: clamped, withRate: 8)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setExposureBias(_ bias: Float) {
        exposureBias = bias
        sessionQueue.async {
            self.exposureBiasSnapshot = bias
            if let device = self.currentDevice { self.applyExposureBias(bias, to: device) }
        }
    }

    /// normalized: 相机帧内的归一化坐标（左上为原点，已转正）。
    func focus(normalized: CGPoint) {
        var u = normalized.x
        let v = normalized.y
        if position == .front { u = 1 - u }

        let devicePoint: CGPoint
        switch Int(previewAngle.rounded()) {
        case 90: devicePoint = CGPoint(x: v, y: 1 - u)
        case 180: devicePoint = CGPoint(x: 1 - u, y: 1 - v)
        case 270: devicePoint = CGPoint(x: 1 - v, y: u)
        default: devicePoint = CGPoint(x: u, y: v)
        }
        let clamped = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))

        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = clamped
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = clamped
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Capture

    func capture(look: FilmLook, aspect: AspectRatio, grainScale: Float, keepOriginal: Bool, watermark: String?, portrait: PortraitOptions? = nil) {
        guard status == .running else { return }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let isFront = position == .front
        processingCount += 1

        sessionQueue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { self.processingCount = max(0, self.processingCount - 1) }
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // 人像：画质优先（多帧合成、Deep Fusion 等由系统决定），胶片模式保持快门速度
            settings.photoQualityPrioritization = portrait != nil ? .quality : .balanced
            // 超广角拍人时自动校正边缘人脸变形
            if self.photoOutput.isContentAwareDistortionCorrectionSupported {
                settings.isAutoContentAwareDistortionCorrectionEnabled = true
            }

            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = isFront
                }
            }

            self.pendingLock.lock()
            self.pending[settings.uniqueID] = PendingCapture(look: look, aspect: aspect, grainScale: grainScale, keepOriginal: keepOriginal, watermark: watermark, portrait: portrait)
            self.pendingLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func takePending(_ id: Int64) -> PendingCapture? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func finishProcessing(thumbnail: UIImage?, error: String?) {
        DispatchQueue.main.async {
            self.processingCount = max(0, self.processingCount - 1)
            if let thumbnail { self.lastThumbnail = thumbnail }
            if let error { self.message = error }
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        frames.set(image)
        let size = image.extent.size
        if size != lastFrameSize {
            lastFrameSize = size
            DispatchQueue.main.async { self.frameSize = size }
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let job = takePending(photo.resolvedSettings.uniqueID) else { return }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            finishProcessing(thumbnail: nil, error: "拍摄失败，请重试")
            return
        }
        processingQueue.async {
            guard let result = PhotoRenderer.render(data: data, look: job.look, aspect: job.aspect,
                                                    grainScale: job.grainScale, watermark: job.watermark, portrait: job.portrait,
                                                    context: self.photoContext) else {
                self.finishProcessing(thumbnail: nil, error: "冲洗失败，请重试")
                return
            }
            PhotoLibrary.save(result.data, original: job.keepOriginal ? data : nil) { success in
                self.finishProcessing(thumbnail: success ? result.thumbnail : nil,
                                      error: success ? nil : "无法保存到相册：请在「设置 › 银盐 › 照片」中允许添加照片")
            }
        }
    }
}
