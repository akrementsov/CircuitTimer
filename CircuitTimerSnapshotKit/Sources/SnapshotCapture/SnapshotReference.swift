import Foundation
import SnapshotTesting
import UIKit

@MainActor
struct SnapshotReference {
    let directory: URL
    let url: URL
    let relativePath: String
    private let testName: String
    private let variantName: String

    init(filePath: StaticString, testName: String, variantName: String) {
        let file = URL(fileURLWithPath: filePath.description)
        let name = file.deletingPathExtension().lastPathComponent
        directory = file.deletingLastPathComponent().appendingPathComponent("__Snapshots__").appendingPathComponent(name)
        url = directory.appendingPathComponent("\(testName).\(variantName).png")
        relativePath = "\(name)/\(testName).\(variantName).png"
        self.testName = testName
        self.variantName = variantName
    }

    func validateNames() throws {
        for name in [testName, variantName] {
            let sanitized = name.replacingOccurrences(of: "\\W+", with: "-", options: .regularExpression)
                .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
            guard !name.isEmpty, name == sanitized else {
                throw SnapshotCaptureFailure("SnapshotTesting would rewrite the snapshot name '\(name)'.")
            }
        }
    }

    static func recordMode() throws -> SnapshotTestingConfiguration.Record {
        switch ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"] {
            case nil, "never": .never
            case "failed": .failed
            case let value:
                throw SnapshotCaptureFailure("Unsupported SNAPSHOT_TESTING_RECORD '\(value ?? "")'; use make record-snapshots.")
        }
    }

    func load() throws -> (data: Data, image: UIImage)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data, scale: SnapshotViewport.scale), let raster = image.cgImage,
              raster.width == Int(SnapshotViewport.pixelSize.width), raster.height == Int(SnapshotViewport.pixelSize.height) else {
            throw SnapshotCaptureFailure("Invalid reference at \(url.path); delete it and run make record-snapshots.")
        }
        return (data, image)
    }
}
