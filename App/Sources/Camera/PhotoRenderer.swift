import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// 成片冲洗：原始照片数据 → 裁切 → 胶片管线 → 带 EXIF 的 HEIC。
enum PhotoRenderer {
    struct Result {
        let data: Data
        let thumbnail: UIImage
    }

    static func render(data: Data, look: FilmLook, aspect: AspectRatio, grainScale: Float, watermark: String?, context: CIContext) -> Result? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }

        var image = aspect.crop(source)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
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
