import Foundation
import UIKit

@MainActor
struct SnapshotJournal {
    private let artifacts = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"]

    func append(key: String, path: String, attempt: String, outcome: String) throws {
        guard let artifacts else { return }
        guard !artifacts.isEmpty else { throw SnapshotCaptureFailure("SNAPSHOT_ARTIFACTS must not be empty.") }
        let directory = URL(fileURLWithPath: artifacts, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("snapshots.tsv")
        let previous: String
        if FileManager.default.fileExists(atPath: url.path) {
            previous = try String(contentsOf: url, encoding: .utf8)
        } else {
            let size = ProcessInfo.processInfo.environment["SNAPSHOT_TEXT_SIZE"] ?? "missing"
            previous = "# runtime \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
                + "# text-size \(size) \(UIApplication.shared.preferredContentSizeCategory.rawValue)\n"
        }
        try (previous + "\(key)\t\(path)\t\(attempt)\t\(outcome)\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
