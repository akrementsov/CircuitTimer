import Foundation
import UIKit

@MainActor
enum SnapshotRasterDiagnostics {
    // Differing edge pixels and neighbouring controls from CI run 39163297090.
    private static let points: [(column: Int, row: Int)] = [
        (120, 2107), (120, 2143), (119, 2143), (121, 2143), (120, 2142), (120, 2144),
        (1149, 2126), (839, 2554), (404, 2375), (416, 2385), (357, 2390), (848, 2390),
        (531, 2546), (906, 2487), (332, 2538), (836, 2552)
    ]

    static func write(
        key: String, reference: UIImage?, first: UIImage,
        second: UIImage? = nil, secondData: Data? = nil
    ) throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_RASTER_DIAGNOSTICS"] == "1" else { return }
        guard let artifacts = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"], !artifacts.isEmpty else {
            throw SnapshotCaptureFailure("Raster diagnostics require SNAPSHOT_ARTIFACTS.")
        }
        var report: [String: Any] = [
            "key": key, "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
            "firstNative": try describe(first)
        ]
        if let reference { report["reference"] = try describe(reference) }
        if let second { report["secondNative"] = try describe(second) }
        if let secondData {
            guard let decoded = UIImage(data: secondData) else {
                throw SnapshotCaptureFailure("Raster diagnostics could not decode the comparison PNG.")
            }
            report["secondPNGRoundtrip"] = try describe(decoded)
        }
        let directory = URL(fileURLWithPath: artifacts, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("\(key)-raster.json"), options: .atomic)
    }

    private static func describe(_ image: UIImage) throws -> [String: Any] {
        guard let raster = image.cgImage, let providerData = raster.dataProvider?.data else {
            throw SnapshotCaptureFailure("Raster diagnostics could not read the image's native data.")
        }
        let raw = providerData as Data
        let length = raster.bitsPerPixel / 8
        let samples = try points.map { point -> [String: Any] in
            let start = point.row * raster.bytesPerRow + point.column * length
            guard length > 0, point.column < raster.width, point.row < raster.height, start + length <= raw.count else {
                throw SnapshotCaptureFailure("Raster diagnostics could not read a probe pixel's native bytes.")
            }
            return ["x": point.column, "y": point.row, "rawBytes": Array(raw[start..<(start + length)])]
        }
        return [
            "width": raster.width, "height": raster.height,
            "bitsPerComponent": raster.bitsPerComponent, "bitsPerPixel": raster.bitsPerPixel,
            "bitmapInfo": raster.bitmapInfo.rawValue, "bytesPerRow": raster.bytesPerRow,
            "colorSpace": raster.colorSpace?.name as String? ?? "unknown",
            "renderingIntent": raster.renderingIntent.rawValue, "samples": samples
        ]
    }
}
