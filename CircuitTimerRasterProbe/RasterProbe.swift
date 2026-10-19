import CryptoKit
import Foundation
import Metal
import os
import SwiftUI
import UIKit

@MainActor
enum RasterProbe {
    static var directory: URL { URL.documentsDirectory.appendingPathComponent("RasterProbe", isDirectory: true) }

    static func run(anchor: UIWindow) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while anchor.windowScene?.activationState != .foregroundActive {
            guard ContinuousClock.now < deadline else { throw ProbeFailure("Scene did not become active") }
            await runLoopTurn()
        }
        guard let scene = anchor.windowScene, scene.coordinateSpace.bounds.size == PrimitiveRenderer.size,
              scene.screen.scale == PrimitiveRenderer.scale else { throw ProbeFailure("Expected 402x874 at3x") }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 27, version.minorVersion == 0, version.patchVersion == 0 else {
            throw ProbeFailure("Expected iOS27.0")
        }
        var cases: [[String: Any]] = []
        var failures: [[String: String]] = []
        for renderer in PrimitiveRenderer.allCases {
            for rounded in [true, false] {
                for antialias in [true, false] {
                    for halfPixel in [false, true] {
                        let sample = PrimitiveRenderer.Sample(rounded: rounded, antialias: antialias, halfPixel: halfPixel)
                        for repetition in 1...2 {
                            try Task.checkCancellation()
                            do {
                                let capture = try await renderer.capture(sample, anchor: anchor)
                                cases.append(try save(capture, renderer: renderer, sample: sample, repetition: repetition))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                let key = "\(renderer.rawValue)-\(sample.key)-\(repetition)"
                                let message = String(reflecting: error)
                                Logger(subsystem: "CircuitTimerRasterProbe", category: "Capture")
                                    .error("Capture \(key, privacy: .public) failed: \(message, privacy: .public)")
                                failures.append(["id": key, "error": message])
                            }
                            await runLoopTurn()
                        }
                    }
                }
            }
        }
        let report: [String: Any] = [
            "status": failures.isEmpty ? "complete" : "partial", "failures": failures,
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
            "metalDevice": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
            "screenGamut": scene.screen.traitCollection.displayGamut.rawValue,
            "scale": PrimitiveRenderer.scale, "roi": [114, 2121, 64, 64],
            "foreground": try color(PrimitiveRenderer.resolved(PrimitiveRenderer.foreground)),
            "background": try color(PrimitiveRenderer.resolved(PrimitiveRenderer.background)),
            "cases": cases
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        return failures.count
    }

    private static func save(
        _ capture: PrimitiveRenderer.Capture,
        renderer: PrimitiveRenderer,
        sample: PrimitiveRenderer.Sample,
        repetition: Int
    ) throws -> [String: Any] {
        let image = capture.image
        let key = "\(renderer.rawValue)-\(sample.key)-\(repetition)"
        let provider = image.dataProvider?.data
        let png = UIImage(cgImage: image, scale: PrimitiveRenderer.scale, orientation: .up).pngData()
        let observation: [String: Any] = [
            "width": image.width, "height": image.height, "bytesPerRow": image.bytesPerRow,
            "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
            "bitmapInfo": image.bitmapInfo.rawValue, "colorSpace": image.colorSpace?.name as String? ?? "unknown",
            "providerBytes": provider.map { CFDataGetLength($0) } ?? -1, "pngBytes": png?.count ?? -1,
            "path": try commands(sample.path.cgPath), "environment": capture.environment
        ]
        try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("\(key).observation.json"), options: .atomic)
        if let png { try png.write(to: directory.appendingPathComponent("\(key).png"), options: .atomic) }
        guard image.width == 1206, image.height == 2622 else {
            throw ProbeFailure("Unexpected raster size \(image.width)x\(image.height): \(key)")
        }
        guard let provider else { throw ProbeFailure("No native provider bytes: \(key)") }
        guard png != nil else { throw ProbeFailure("PNG encoding failed: \(key)") }
        let raw = provider as Data
        let stride = image.bitsPerPixel / 8
        guard stride > 0, raw.count >= image.bytesPerRow * image.height else { throw ProbeFailure("Invalid native buffer") }
        var patch = Data()
        for row in 2121..<(2121 + 64) {
            let start = row * image.bytesPerRow + 114 * stride
            patch.append(raw[start..<(start + 64 * stride)])
        }
        try patch.write(to: directory.appendingPathComponent("\(key).native"), options: .atomic)
        let center = CGPoint(x: Int((sample.origin.x + 8.5) * 3), y: Int((sample.origin.y + 8.5) * 3))
        let background = try pixel(image, at: .zero)
        let foreground = try pixel(image, at: center)
        guard foreground[1] > foreground[0] + 40, foreground[2] > foreground[0] + 40,
              foreground[3] == 255, background[3] == 255 else { throw ProbeFailure("Blank or misplaced marker: \(key)") }
        return [
            "id": key, "renderer": renderer.rawValue, "shape": sample.rounded ? "rounded" : "rectangle",
            "antialias": sample.antialias, "phase": sample.halfPixel ? "half" : "integer", "repeat": repetition,
            "origin": [Double(sample.origin.x), Double(sample.origin.y)], "path": try commands(sample.path.cgPath),
            "native": [
                "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
                "bitmapInfo": image.bitmapInfo.rawValue, "colorSpace": image.colorSpace?.name as String? ?? "unknown"
            ],
            "nativeSHA256": SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined(),
            "validation": ["background": background, "center": foreground], "environment": capture.environment
        ]
    }

    static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ProbeFailure("Could not allocate an sRGB bitmap")
        }
        return context
    }

    private static func pixel(_ image: CGImage, at point: CGPoint) throws -> [Int] {
        guard let crop = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))) else {
            throw ProbeFailure("Could not crop a validation pixel")
        }
        let context = try bitmap(width: 1, height: 1)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ProbeFailure("No pixel data") }
        return (0..<4).map { Int(data[$0]) }
    }

    private static func color(_ value: CGColor) -> [String: Any] {
        let components = value.components ?? []
        return [
            "space": value.colorSpace?.name as String? ?? "unknown", "components": components,
            "componentBits": components.map { String(Double($0).bitPattern, radix: 16) }
        ]
    }

    private static func commands(_ path: CGPath) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var unsupported = false
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count: Int
            switch element.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                case .closeSubpath: count = 0
                @unknown default: count = 0; unsupported = true
            }
            let points = (0..<count).map { index in
                let point = element.points[index]
                return ["x": String(Double(point.x).bitPattern, radix: 16), "y": String(Double(point.y).bitPattern, radix: 16)]
            }
            result.append(["type": element.type.rawValue, "points": points])
        }
        guard !unsupported else { throw ProbeFailure("Unsupported path element") }
        return result
    }

    static func runLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
