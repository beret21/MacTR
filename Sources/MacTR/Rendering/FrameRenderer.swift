// FrameRenderer.swift — Protocol for display set renderers
//
// Each display set implements this protocol.
// The frame loop calls render() to get a CGImage, then encodes it to JPEG.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: - Protocol

protocol FrameRenderer {
    /// Render a full 1920x480 frame. Returns CGImage in device orientation.
    func render() -> CGImage?
}

// MARK: - JPEG Encoding

enum JPEGEncoder {

    // Reusable context for 180° rotation — prevents CG raster data leak
    nonisolated(unsafe) private static var rotateCtx: CGContext?

    /// Encode CGImage to JPEG Data with 180° rotation and brightness adjustment.
    /// Reduces quality if over 650KB (matches Python behavior).
    static func encode(
        _ image: CGImage, brightness: Int = 1, maxBytes: Int = 650_000
    ) -> Data? {
        let w = image.width
        let h = image.height

        // Reuse rotation context
        if rotateCtx == nil || rotateCtx!.width != w || rotateCtx!.height != h {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            rotateCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let rotatedCtx = rotateCtx else { return nil }

        // 180° rotation
        rotatedCtx.saveGState()
        rotatedCtx.translateBy(x: CGFloat(w), y: CGFloat(h))
        rotatedCtx.scaleBy(x: -1, y: -1)
        rotatedCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        rotatedCtx.restoreGState()

        guard var finalImage = rotatedCtx.makeImage() else { return nil }

        // Apply brightness if needed
        if brightness > 1 {
            if let brightened = applyBrightness(finalImage, level: brightness) {
                finalImage = brightened
            }
        }

        // Encode to JPEG with quality reduction loop
        var quality = 0.9
        while quality > 0.3 {
            if let data = jpegData(from: finalImage, quality: quality) {
                if data.count <= maxBytes || quality <= 0.3 {
                    return data
                }
            }
            quality -= 0.05
        }
        return jpegData(from: finalImage, quality: 0.3)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // Reusable CIContext for brightness filter
    nonisolated(unsafe) private static var ciCtx: CIContext?

    /// Apply brightness using CIFilter — matches Python ImageEnhance.Brightness behavior.
    /// PIL Brightness multiplies RGB values by factor. CIFilter.colorControls brightness
    /// parameter is additive (-1 to 1), so we use a combination approach.
    private static func applyBrightness(_ image: CGImage, level: Int) -> CGImage? {
        let factor = Brightness.factor(for: level)
        if factor <= 1.0 { return image }

        let ciImage = CIImage(cgImage: image)

        // Use colorMatrix to multiply RGB by factor (same as PIL Brightness)
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        let f = Float(factor)
        filter.setValue(CIVector(x: CGFloat(f), y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: CGFloat(f), z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: CGFloat(f), w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

        guard let output = filter.outputImage else { return nil }
        if ciCtx == nil { ciCtx = CIContext() }
        return ciCtx!.createCGImage(output, from: output.extent)
    }
}
