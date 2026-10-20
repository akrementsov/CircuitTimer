import Foundation
import SnapshotCapture
import Testing

@MainActor
@Suite(.serialized)
struct SnapshotLanguageContractTests {
    @Test(.enabled(if: Locale.preferredLanguages.first?.hasPrefix("de") == true))
    func test_capture_unsupportedProcessLanguage_throwsBeforeRootAndJournalsLanguageCode() async throws {
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        let previous = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"]
        setenv("SNAPSHOT_ARTIFACTS", artifacts.path, 1)
        defer {
            if let previous { setenv("SNAPSHOT_ARTIFACTS", previous, 1) } else { unsetenv("SNAPSHOT_ARTIFACTS") }
            do { try FileManager.default.removeItem(at: artifacts) } catch { Issue.record(error) }
        }
        var roots = 0
        do {
            try await assertFirstFrameSnapshot(
                textSize: .large,
                testName: "test_language",
                filePath: #filePath,
                sourceLocation: #_sourceLocation
            ) { _ in
                roots += 1
                throw SnapshotLanguageContractError.unexpectedRoot
            }
            Issue.record("An unsupported language must throw")
        } catch {
            #expect(String(describing: error).contains("Snapshot language must be en or ru and match the host localization"))
            #expect(String(describing: error).contains("process: de"))
            #expect(String(describing: error).contains("bundle: en"))
        }
        #expect(roots == 0)
        let journal = try String(contentsOf: artifacts.appendingPathComponent("snapshots.tsv"), encoding: .utf8)
        #expect(journal.contains("test_language.de-large\tSnapshotLanguageContractTests/test_language.de-large.png\tfirst\terror\n"))
        #expect(!FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("SnapshotLanguageContractTests").path))
    }
}

private enum SnapshotLanguageContractError: Error { case unexpectedRoot }
