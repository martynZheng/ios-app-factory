import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import Vision

/// 成片冲洗：原始照片数据 → 裁切 → 胶片管线 → 带 EXIF 的 HEIC。
enum PhotoRenderer {
    struct Result {
        let data: Data
        let thumbnail: UIImage
    }

    static func render(data: Data, look: FilmLook, aspect: AspectRatio, grainScale: Float, watermark: String?, portrait: PortraitOptions?, context: CIContext) -> Result? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }

        var image = aspect.crop(source)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let portrait {
            image = PortraitRetouch.apply(portrait, to: image)
        }
        image = FilmProcessor.shared.apply(look, to: image, grainScale: grainScale, seed: CGFloat.random(in: 0...4000))
        if let watermark, !watermark.isEmpty {
            image = Watermark.apply(watermark, to: image)
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }

        var properties = source.properties
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "银盐 · \(look.name)"
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let thumbScale = 240 / max(image.extent.width, image.extent.height)
        let thumbImage = image.transformed(by: CGAffineTransform(scaleX: thumbScale, y: thumbScale))
        let thumbnail: UIImage
        if let thumbCG = context.createCGImage(thumbImage, from: thumbImage.extent) {
            thumbnail = UIImage(cgImage: thumbCG)
        } else {
            thumbnail = UIImage(cgImage: cgImage)
        }

        return Result(data: output as Data, thumbnail: thumbnail)
    }
}

enum PhotoLibrary {
    static func save(_ data: Data, original: Data?, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if let original {
                    let originalRequest = PHAssetCreationRequest.forAsset()
                    originalRequest.addResource(with: .photo, data: original, options: nil)
                }
            }, completionHandler: { success, _ in
                completion(success)
            })
        }
    }
}

/// 水印：右下角一行斜体小字。尺寸按画面短边归一化，取景器里的预览（WatermarkPreview）用同样的比例。
enum Watermark {
    static let fontName = "Georgia-Italic"
    static let sizeRatio: CGFloat = 0.026     // 字号 / 短边
    static let marginRatio: CGFloat = 0.035   // 边距 / 短边

    static func apply(_ text: String, to image: CIImage) -> CIImage {
        let e = image.extent
        let shortSide = min(e.width, e.height)
        let fontSize = max(12, shortSide * sizeRatio)
        let font = UIFont(name: fontName, size: fontSize) ?? UIFont.italicSystemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            .kern: fontSize * 0.03,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let pad = fontSize * 0.6
        let canvas = CGSize(width: ceil(textSize.width + pad * 2), height: ceil(textSize.height + pad * 2))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            context.cgContext.setShadow(offset: .zero, blur: fontSize * 0.35,
                                        color: UIColor.black.withAlphaComponent(0.45).cgColor)
            string.draw(at: CGPoint(x: pad, y: pad))
        }
        guard let cgImage = rendered.cgImage else { return image }

        let margin = shortSide * marginRatio
        let x = e.maxX - margin - textSize.width - pad
        let y = e.minY + margin - pad
        let stamp = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: x, y: y))
        return stamp.composited(over: image).cropped(to: e)
    }
}

/// 人像成片处理的参数。
struct PortraitOptions {
    var smoothing: Float          // 磨皮强度 0~1
    var backgroundSoft: Float     // 背景柔化（甜水空气感）0~1
}

/// 人像后期：人像分割 → 肤色区域磨皮（保留纹理）→ 背景轻柔化提亮。
enum PortraitRetouch {
    static func apply(_ options: PortraitOptions, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let shortSide = min(extent.width, extent.height)

        // 人像分割蒙版（白 = 人）
        var personMask: CIImage?
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        if (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer {
            let mask = CIImage(cvPixelBuffer: buffer)
            let sx = extent.width / mask.extent.width
            let sy = extent.height / mask.extent.height
            personMask = mask
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shortSide * 0.004])
                .cropped(to: extent)
        }

        // 0. 清晰度：先整体轻锐化（亮度通道），随后磨皮会把皮肤区域换回柔和版，
        //    于是眼睛、睫毛、头发、衣服纹理更清楚，而皮肤保持干净。
        var out = image
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.45,
                kCIInputRadiusKey: max(1.2, shortSide * 0.0009),
            ])
            .cropped(to: extent)

        // 1. 磨皮：只在“人身上 × 像肤色”的区域，把模糊版按强度混回，保留部分纹理
        if options.smoothing > 0.01 {
            let radius = max(1.5, shortSide * 0.0045)
            let blurred = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            var mask = FilmProcessor.shared.skinMask(image)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.8])
                .cropped(to: extent)
            if let personMask {
                mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: personMask])
            }
            let k = CGFloat(min(options.smoothing, 1)) * 0.85
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            out = blurred.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: mask,
            ])
        }

        // 2. 背景柔化：背景轻微模糊 + 提亮，主体保持清晰
        if options.backgroundSoft > 0.01, let personMask {
            let soft = CGFloat(min(options.backgroundSoft, 1))
            let background = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shortSide * 0.006 * soft])
                .cropped(to: extent)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.03 * soft,
                    kCIInputContrastKey: 1 - 0.06 * soft,
                ])
            out = out.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: personMask,
            ])
        }
        return out.cropped(to: extent)
    }
}
