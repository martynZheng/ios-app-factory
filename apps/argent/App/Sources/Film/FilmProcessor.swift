import CoreImage
import Foundation

/// 胶片处理管线：3D LUT（色彩+影调） → 高光红晕 → 颗粒 → 暗角。
/// 取景器（约 2K）和成片（约 24MP）走同一条管线；颗粒、光晕等尺寸都按画面宽度归一化，
/// 所以取景器里看到的质感和最终照片一致。
final class FilmProcessor {
    static let shared = FilmProcessor()

    private let cubeSize = 33
    private var cubes: [String: Data] = [:]
    private let lock = NSLock()
    private let lutSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private let noise: CIImage = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))

    func apply(_ look: FilmLook, to image: CIImage, grainScale: Float, seed: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, !extent.isInfinite else { return image }

        var out = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": cube(for: look),
            "inputColorSpace": lutSpace,
        ])

        if look.halation > 0.01 {
            out = addHalation(out, amount: CGFloat(look.halation), extent: extent)
        }

        if look.glow > 0.01 {
            out = addGlow(out, amount: CGFloat(look.glow), extent: extent)
        }

        let grain = look.grain * grainScale
        if grain > 0.01 {
            out = addGrain(out, amount: CGFloat(grain), size: CGFloat(look.grainSize), extent: extent, seed: seed)
        }

        if look.vignette > 0.01 {
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.45,
                kCIInputIntensityKey: look.vignette,
                "inputFalloff": 0.75,
            ])
        }

        return out.cropped(to: extent)
    }

    // MARK: - 肤色蒙版（人像磨皮用）

    private lazy var skinCube: Data = {
        let n = cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Float(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let w = Self.skinWeight(SIMD3<Float>(Float(r) / denom, Float(g) / denom, Float(b) / denom))
                    values[i] = w; values[i + 1] = w; values[i + 2] = w; values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// 灰度蒙版：越像肤色越白。
    func skinMask(_ image: CIImage) -> CIImage {
        lock.lock()
        let data = skinCube
        lock.unlock()
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": data,
            "inputColorSpace": lutSpace,
        ])
    }

    // MARK: - LUT

    private func cube(for look: FilmLook) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cubes[look.id] { return cached }
        let data = Self.makeCube(look, size: cubeSize)
        cubes[look.id] = data
        return data
    }

    private static func makeCube(_ look: FilmLook, size n: Int) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Float(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let input = SIMD3<Float>(Float(r) / denom, Float(g) / denom, Float(b) / denom)
                    let o = transform(input, look)
                    values[i] = o.x
                    values[i + 1] = o.y
                    values[i + 2] = o.z
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    private static func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(clamp01(v.x), clamp01(v.y), clamp01(v.z))
    }

    private static func luma(_ c: SIMD3<Float>) -> Float {
        c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
    }

    /// S 曲线：contrast > 0 加反差（>1 再叠一次），< 0 绕中灰压缩。
    private static func curve(_ x: Float, _ contrast: Float) -> Float {
        var y = clamp01(x)
        if contrast >= 0 {
            let s1 = y * y * (3 - 2 * y)
            y += min(contrast, 1) * (s1 - y)
            if contrast > 1 {
                let s2 = y * y * (3 - 2 * y)
                y += min(contrast - 1, 1) * (s2 - y)
            }
        } else {
            y = 0.5 + (y - 0.5) * (1 + contrast * 0.5)
        }
        return y
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    /// 肤色区域权重：色相落在红橙（约 0°–45°）、中等饱和、不太暗的颜色。
    static func skinWeight(_ c: SIMD3<Float>) -> Float {
        let maxC = max(c.x, max(c.y, c.z))
        let minC = min(c.x, min(c.y, c.z))
        let delta = maxC - minC
        guard maxC > 0.18, delta > 0.02 else { return 0 }
        let sat = delta / maxC
        var hue: Float
        if maxC == c.x {
            hue = (c.y - c.z) / delta
        } else if maxC == c.y {
            hue = 2 + (c.z - c.x) / delta
        } else {
            hue = 4 + (c.x - c.y) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        // 色相：0.0~0.13 之间（红到橙黄），两端柔和过渡；略带品红（>0.95）也算
        let hueW: Float
        if hue > 0.95 {
            hueW = smoothstep(0.95, 0.99, hue)
        } else {
            hueW = smoothstep(-0.02, 0.02, hue) * (1 - smoothstep(0.10, 0.15, hue))
        }
        let satW = smoothstep(0.08, 0.18, sat) * (1 - smoothstep(0.62, 0.78, sat))
        let valW = smoothstep(0.18, 0.35, maxC)
        return hueW * satW * valW
    }

    private static func adjustSkin(_ input: SIMD3<Float>, _ look: FilmLook) -> SIMD3<Float> {
        let w = skinWeight(input)
        guard w > 0.001 else { return input }
        var c = input
        // 提亮：向白色方向推中间调，保留高光
        let lift = look.skinBrighten * w * 0.35
        c += (SIMD3<Float>(repeating: 1) - c) * lift * c
        // 气色：微微加红、减绿
        let rosy = look.skinRosy * w
        c.x += 0.035 * rosy
        c.y -= 0.012 * rosy
        c.z += 0.012 * rosy
        // 通透：去黄（加蓝）并略降饱和
        let clear = look.skinClear * w
        c.z += 0.03 * clear
        let l = luma(c)
        c = SIMD3<Float>(repeating: l) + (c - SIMD3<Float>(repeating: l)) * (1 - 0.22 * clear)
        return clamp01(c)
    }

    private static func keyed(_ x: Float, _ key: Float) -> Float {
        clamp01(x + key * 2 * x * (1 - x))
    }

    private static func transform(_ input: SIMD3<Float>, _ look: FilmLook) -> SIMD3<Float> {
        var c = input
        c.x *= 1 + 0.08 * look.warmth
        c.z *= 1 - 0.08 * look.warmth
        c.y *= 1 - 0.04 * look.tint
        c = clamp01(c)

        let blacks = look.blacks
        let range = look.whites - look.blacks

        if look.mono {
            var m = c.x * look.monoMix.x + c.y * look.monoMix.y + c.z * look.monoMix.z
            m = curve(m, look.contrast)
            m = blacks + m * range
            var o = SIMD3<Float>(repeating: m)
            let ws = (1 - m) * (1 - m)
            let wh = m * m
            o += look.shadowTint * ws
            o += look.highlightTint * wh
            return clamp01(o)
        }

        let l = luma(c)
        let grey = SIMD3<Float>(repeating: l)
        c = clamp01(grey + (c - grey) * look.saturation)

        // 色彩铬：越饱和的颜色压得越暗，层次更厚
        if look.chrome > 0 {
            let maxC = max(c.x, max(c.y, c.z))
            let minC = min(c.x, min(c.y, c.z))
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            c *= 1 - look.chrome * 0.32 * sat * sat
        }

        // 高低调：提亮/压暗中间调，黑白两端不动
        if look.key != 0 {
            c = SIMD3<Float>(keyed(c.x, look.key), keyed(c.y, look.key), keyed(c.z, look.key))
        }

        if look.skinBrighten != 0 || look.skinRosy != 0 || look.skinClear != 0 {
            c = adjustSkin(c, look)
        }

        c = SIMD3<Float>(curve(c.x, look.contrast), curve(c.y, look.contrast), curve(c.z, look.contrast))
        c = SIMD3<Float>(repeating: blacks) + c * range

        let l2 = luma(c)
        let ws = (1 - l2) * (1 - l2)
        let wh = l2 * l2
        c += look.shadowTint * ws
        c += look.highlightTint * wh
        return clamp01(c)
    }

    // MARK: - Texture

    /// 高光红晕：提取高光 → 染成橙红 → 大半径模糊 → 滤色叠回。
    private func addHalation(_ image: CIImage, amount: CGFloat, extent: CGRect) -> CIImage {
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let mask = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": lumaVector,
                "inputGVector": lumaVector,
                "inputBVector": lumaVector,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.62, y: 0),
                "inputPoint2": CIVector(x: 0.80, y: 0.12),
                "inputPoint3": CIVector(x: 0.92, y: 0.55),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        let tinted = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0 * amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.30 * amount, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.10 * amount, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let radius = max(2, extent.width * 0.012)
        let glow = tinted
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// 柔光：整幅画面大半径模糊后以较低强度滤色叠回，亮部泛起柔和光晕（≈ 黑柔滤镜 / 甜水感）。
    private func addGlow(_ image: CIImage, amount: CGFloat, extent: CGRect) -> CIImage {
        let radius = max(2, extent.width * 0.014)
        let k = min(amount, 1) * 0.55
        let glow = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// 单色颗粒：随机噪声 → 以 0.5 为中心压缩幅度 → 按画面宽度缩放 → 柔光叠加（中灰不改变原图）。
    private func addGrain(_ image: CIImage, amount: CGFloat, size: CGFloat, extent: CGRect, seed: CGFloat) -> CIImage {
        let k = min(amount, 1.5) * 0.42
        let bias = 0.5 - 0.5 * k
        let scale = max(1, extent.width / 1800) * size
        let grain = noise
            .transformed(by: CGAffineTransform(translationX: seed, y: seed * 0.618))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ])
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        return grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }
}
