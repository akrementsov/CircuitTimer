@testable import SnapshotCapture

import Foundation
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SnapshotCaptureTests {
    @Test(arguments: [0, 1, 2])
    func test_compare_channelDeltaWithinLimit_accepts(delta: UInt8) throws {
        let reference = try image()
        let actual = try image(changedPixels: 1, delta: delta)
        #expect(SnapshotImageComparison.strategy.diffing.diffV2(reference, actual) == nil)
    }

    @Test(arguments: [0, 1, 2])
    func test_compare_channelAboveLimit_rejects(channel: Int) throws {
        let reference = try image()
        let actual = try image(changedPixels: 1, delta: 3, channel: channel)
        let mismatch = try #require(SnapshotImageComparison.strategy.diffing.diffV2(reference, actual))
        #expect(mismatch.0.contains("RGB differs by 3/255"))
        #expect(mismatch.0.contains("maximum allowed difference is 2/255"))
    }

    @Test(arguments: [160, 161, 1206 * 2622])
    func test_compare_areaBoundary_usesBothBounds(pixelCount: Int) throws {
        let width = pixelCount == 1206 * 2622 ? 1206 : pixelCount
        let height = pixelCount == 1206 * 2622 ? 2622 : 1
        let reference = try image(width: width, height: height)
        let atLimit = try image(width: width, height: height, changedPixels: pixelCount / 80, delta: 1)
        let beyondLimit = try image(width: width, height: height, changedPixels: pixelCount / 80 + 1, delta: 1)
        let wholeImage = try image(width: width, height: height, changedPixels: pixelCount, delta: 1)
        let diffing = SnapshotImageComparison.strategy.diffing
        #expect(diffing.diffV2(reference, atLimit) == nil)
        #expect(try #require(diffing.diffV2(reference, beyondLimit)).0.contains("More than 1.25%"))
        #expect(try #require(diffing.diffV2(reference, wholeImage)).0.contains("More than 1.25%"))
    }

    @Test
    func test_compare_onlyAlphaDiffers_rejectsWithCoordinates() throws {
        let reference = try image()
        let actual = try image(alpha: 254)
        let mismatch = try #require(SnapshotImageComparison.strategy.diffing.diffV2(reference, actual))
        #expect(mismatch.0 == "Snapshot transparency differs at pixel 0,0.")
    }

    @Test(arguments: ["", "-leading", "trailing-", "a/b", "two words"])
    func test_validateNames_rewrittenName_throws(name: String) throws {
        let reference = SnapshotReference(filePath: #filePath, testName: name, variantName: "en-large")
        #expect(throws: (any Error).self) { try reference.validateNames() }
    }

    @Test(arguments: ["garbage", "wrong-size"])
    func test_load_invalidReference_reportsRecovery(input: String) throws {
        let reference = try makeReference()
        defer { removeReference(reference) }
        let smallImage = try image()
        let data = input == "garbage" ? Data("not PNG".utf8) : try #require(smallImage.pngData())
        try data.write(to: reference.url)
        do {
            _ = try reference.load()
            Issue.record("Invalid reference was accepted")
        } catch {
            #expect(String(describing: error).contains("Invalid reference at \(reference.url.path)"))
            #expect(String(describing: error).contains("delete it and run make record-snapshots"))
        }
    }

    @Test
    func test_load_missingReference_returnsNilWithoutCreatingFile() throws {
        let reference = try makeReference()
        defer { removeReference(reference) }
        #expect(try reference.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: reference.url.path))
    }

    @Test
    func test_load_validReference_preservesBytesAndDimensions() throws {
        let reference = try makeReference()
        defer { removeReference(reference) }
        let referenceImage = try image(width: 1206, height: 2622)
        let data = try #require(referenceImage.pngData())
        try data.write(to: reference.url)
        let result = try reference.load()
        let loaded = try #require(result)
        #expect(loaded.data == data)
        #expect(loaded.image.cgImage?.width == 1206)
        #expect(loaded.image.cgImage?.height == 2622)
    }

    @Test(arguments: [nil, "never", "failed", "all", "missing", ""] as [String?])
    func test_recordMode_environment_acceptsOnlyExplicitModes(value: String?) throws {
        try withEnvironment(["SNAPSHOT_TESTING_RECORD": value]) { () throws in
            switch value {
                case nil, "never": #expect(try SnapshotReference.recordMode() == .never)
                case "failed": #expect(try SnapshotReference.recordMode() == .failed)
                default:
                    do {
                        _ = try SnapshotReference.recordMode()
                        Issue.record("Unsupported recording mode was accepted")
                    } catch {
                        #expect(String(describing: error).contains("Unsupported SNAPSHOT_TESTING_RECORD"))
                    }
            }
        }
    }

    @Test(arguments: [nil, "unknown", "large", "ax5"] as [String?])
    func test_currentCases_processSelection_keepsInvalidLaunchDiscoverable(value: String?) throws {
        withEnvironment(["SNAPSHOT_TEXT_SIZE": value]) {
            let expected: [SnapshotTextSize]
            switch value {
                case "large": expected = [.large]
                case "ax5": expected = [.ax5]
                default: expected = [.large, .ax5]
            }
            #expect(SnapshotTextSize.currentCases() == expected)
            #expect(SnapshotTextSize.currentCases(in: [.large]) == expected.filter { $0 == .large })
        }
    }

    @Test(arguments: [nil, "unknown", "ax5"] as [String?])
    func test_validateProcess_wrongSelection_failsLoudly(value: String?) throws {
        withEnvironment(["SNAPSHOT_TEXT_SIZE": value]) {
            do {
                try SnapshotTextSize.large.validateProcess()
                Issue.record("Invalid process selection was accepted")
            } catch {
                #expect(String(describing: error).contains("Snapshot text size must match its process"))
                #expect(String(describing: error).contains("Use make test-snapshots"))
            }
        }
    }

    @Test
    func test_validateProcess_argumentMatchesButUIKitDoesNot_throws() throws {
        let wrongSize: SnapshotTextSize = UIApplication.shared.preferredContentSizeCategory == .large ? .ax5 : .large
        withEnvironment(["SNAPSHOT_TEXT_SIZE": wrongSize.rawValue]) {
            #expect(throws: (any Error).self) { try wrongSize.validateProcess() }
        }
    }

    @Test
    func test_journal_noArtifacts_isNoOp() throws {
        try withEnvironment(["SNAPSHOT_ARTIFACTS": nil]) {
            try SnapshotJournal().append(key: "test.en-large", path: "File/test.en-large.png", attempt: "first", outcome: "passed")
        }
    }

    @Test
    func test_journal_appendsCases_keepsProcessHeaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { removeDirectory(directory) }
        try withEnvironment(["SNAPSHOT_ARTIFACTS": directory.path, "SNAPSHOT_TEXT_SIZE": "large"]) {
            let journal = SnapshotJournal()
            try journal.append(key: "first.en-large", path: "File/first.en-large.png", attempt: "first", outcome: "passed")
            try journal.append(key: "second.en-large", path: "File/second.en-large.png", attempt: "second", outcome: "failed")
            let lines = try String(contentsOf: directory.appendingPathComponent("snapshots.tsv"), encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 4)
            #expect(lines[0].hasPrefix("# runtime "))
            #expect(lines[1] == "# text-size large \(UIApplication.shared.preferredContentSizeCategory.rawValue)")
            #expect(lines[2] == "first.en-large\tFile/first.en-large.png\tfirst\tpassed")
            #expect(lines[3] == "second.en-large\tFile/second.en-large.png\tsecond\tfailed")
        }
    }

    @Test(arguments: ["", "/dev/null/invalid"])
    func test_journal_invalidDirectory_throws(path: String) throws {
        withEnvironment(["SNAPSHOT_ARTIFACTS": path]) {
            #expect(throws: (any Error).self) {
                try SnapshotJournal().append(key: "test.en-large", path: "File/test.en-large.png", attempt: "first", outcome: "error")
            }
        }
    }

    private func image(
        width: Int = 160,
        height: Int = 1,
        changedPixels: Int = 0,
        delta: UInt8 = 0,
        channel: Int = 0,
        alpha: UInt8 = 255
    ) throws -> UIImage {
        var bytes = [UInt8](repeating: 64, count: width * height * 4)
        for pixel in 0..<(width * height) { bytes[pixel * 4 + 3] = alpha }
        for pixel in 0..<changedPixels { bytes[pixel * 4 + channel] += delta }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let raster = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return UIImage(cgImage: raster, scale: 3, orientation: .up)
    }

    private func makeReference() throws -> SnapshotReference {
        let reference = SnapshotReference(filePath: #filePath, testName: "test_\(UUID().uuidString)", variantName: "en-large")
        try FileManager.default.createDirectory(at: reference.directory, withIntermediateDirectories: true)
        return reference
    }

    private func removeReference(_ reference: SnapshotReference) {
        do {
            if FileManager.default.fileExists(atPath: reference.url.path) { try FileManager.default.removeItem(at: reference.url) }
            if try FileManager.default.contentsOfDirectory(atPath: reference.directory.path).isEmpty {
                try FileManager.default.removeItem(at: reference.directory)
            }
        } catch { Issue.record(error) }
    }

    private func removeDirectory(_ directory: URL) {
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        } catch { Issue.record(error) }
    }

    private func withEnvironment(_ values: [String: String?], operation: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment
        defer {
            for key in values.keys {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in values {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        return try operation()
    }
}
