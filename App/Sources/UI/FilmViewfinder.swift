import CoreImage
import MetalKit
import SwiftUI

/// 实时胶片取景：把最新的相机帧铺满（aspect fill）后走胶片管线，用 Metal 画出来。
struct FilmViewfinder: UIViewRepresentable {
    let frames: FrameBuffer
    var look: FilmLook
    var grainScale: Float

    func makeCoordinator() -> ViewfinderRenderer {
        ViewfinderRenderer(frames: frames)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.look = look
        context.coordinator.grainScale = grainScale
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.look = look
        context.coordinator.grainScale = grainScale
    }
}

final class ViewfinderRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    var look: FilmLook = FilmLook.all[0]
    var grainScale: Float = 1

    private let frames: FrameBuffer
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext
    private let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var tick = 0

    init(frames: FrameBuffer) {
        self.frames = frames
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext()
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 1, size.height > 1,
              let frame = frames.get(),
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let scale = max(size.width / extent.width, size.height / extent.height)
        var image = frame
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaled = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - scaled.width) / 2,
                                                        y: (size.height - scaled.height) / 2))
        let bounds = CGRect(origin: .zero, size: size)
        image = image.cropped(to: bounds)

        // 颗粒每帧换一个随机偏移，取景器里会“活”起来，和真实胶片颗粒一样。
        tick = (tick + 1) % 4096
        let seed = CGFloat((tick * 7919) % 3001)
        let film = FilmProcessor.shared.apply(look, to: image, grainScale: grainScale, seed: seed)
        let output = film.composited(over: CIImage(color: CIColor.black).cropped(to: bounds))

        context.render(output, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// 只为承载 RotationCoordinator 所需的预览层，不可见。
struct RotationAnchor: UIViewRepresentable {
    let layer: CALayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}
