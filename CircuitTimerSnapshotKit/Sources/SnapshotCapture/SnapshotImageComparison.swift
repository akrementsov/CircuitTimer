import Foundation
import os
import SnapshotTesting
import UIKit

@MainActor
enum SnapshotImageComparison {
    private static let maximumChannelDelta = 2
    private static let changedPixelDivisor = 80

    static var strategy: Snapshotting<UIImage, UIImage> {
        let strict = Snapshotting<UIImage, UIImage>.image(precision: 1, perceptualPrecision: 1, scale: SnapshotViewport.scale)
        var strategy = strict
        strategy.diffing.diffV2 = { reference, actual in
            do {
                guard let message = try mismatch(reference, actual) else { return nil }
                return (message, strict.diffing.diffV2(reference, actual)?.1 ?? [])
            } catch {
                SnapshotCaptureFailure.logger.error("Snapshot comparison failed: \(String(reflecting: error), privacy: .public)")
                return ("Snapshot comparison failed: \(error)", [])
            }
        }
        return strategy
    }

    private static func mismatch(_ reference: UIImage, _ actual: UIImage) throws -> String? {
        guard let oldImage = reference.cgImage, let newImage = actual.cgImage else {
            return "A snapshot has no raster to compare."
        }
        guard oldImage.width > 0, oldImage.height > 0,
              oldImage.width == newImage.width, oldImage.height == newImage.height else {
            return "Snapshot pixel dimensions do not match."
        }
        let oldPixels = try pixels(oldImage)
        let newPixels = try pixels(newImage)
        if oldPixels == newPixels { return nil }

        let pixelCount = oldImage.width * oldImage.height
        // Both bounds apply: <=2/255 in each RGB channel and <=1.25% changed pixels; alpha is exact.
        let allowedChangedPixels = pixelCount / changedPixelDivisor
        return oldPixels.withUnsafeBufferPointer { old in
            newPixels.withUnsafeBufferPointer { new in
                var changedPixels = 0
                for pixel in 0..<pixelCount {
                    let offset = pixel * 4
                    if old[offset + 3] != new[offset + 3] {
                        return "Snapshot transparency differs at pixel \(pixel % oldImage.width),\(pixel / oldImage.width)."
                    }
                    let delta = max(
                        abs(Int(old[offset]) - Int(new[offset])),
                        abs(Int(old[offset + 1]) - Int(new[offset + 1])),
                        abs(Int(old[offset + 2]) - Int(new[offset + 2]))
                    )
                    if delta > maximumChannelDelta {
                        return "Snapshot RGB differs by \(delta)/255; the maximum allowed difference is \(maximumChannelDelta)/255."
                    }
                    if delta > 0 {
                        changedPixels += 1
                        if changedPixels > allowedChangedPixels {
                            return "More than 1.25% of snapshot pixels differ (maximum \(allowedChangedPixels) of \(pixelCount))."
                        }
                    }
                }
                return nil
            }
        }
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SnapshotCaptureFailure("Could not create the comparison's sRGB color space.")
        }
        // Match SnapshotTesting's 8-bit sRGB normalization before applying byte-level bounds.
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw SnapshotCaptureFailure("Could not render the snapshot into comparison pixels.") }
        return pixels
    }
}
