@testable import SnapshotCapture

import Foundation
import Testing
import UIKit

extension SnapshotCaptureTests {
    nonisolated private static var isSnapshotRuntime: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 0
    }

    @Test(arguments: [[27, 0, 0], [17, 5, 0], [26, 5, 0], [27, 0, 1], [27, 1, 0], [28, 0, 0]])
    func test_validateRuntime_version_acceptsOnlyExactSupportedRuntime(parts: [Int]) throws {
        let version = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts[2])
        do {
            try SnapshotViewport.validateRuntime(version)
            #expect(parts == [27, 0, 0])
        } catch {
            #expect(parts != [27, 0, 0])
            #expect(String(describing: error).contains("Snapshots require the iOS 27.0 simulator"))
            #expect(String(describing: error).contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
    }

    @Test(arguments: ["de-DE", "ru-RU", "en-US", "missing"])
    func test_languageCode_preferredLanguage_usesCodeOrNil(input: String) {
        let expected = ["de-DE": "de", "ru-RU": "ru", "en-US": "en"]
        #expect(SnapshotLanguage.languageCode(in: input == "missing" ? [] : [input]) == expected[input])
    }

    @Test(.enabled(if: Self.isSnapshotRuntime))
    func test_firstFrame_withoutScene_exhaustsOneProcessBudget() async throws {
        #expect(UIApplication.shared.connectedScenes.isEmpty)
        var roots = 0
        let firstStart = ContinuousClock.now
        for attempt in 0..<2 {
            let start = ContinuousClock.now
            do {
                _ = try await SnapshotWindow.firstFrame(variant: SnapshotVariant(language: .english, textSize: .large)) { _ in
                    roots += 1
                    return SnapshotRoot(controller: UIViewController(), tabBar: .none)
                }
                Issue.record("A window cannot be captured without an active scene")
            } catch {
                #expect(String(describing: error).contains("10-second activation budget is exhausted"))
            }
            // The startup budget uses a real clock by design; the second call must not start another 10-second wait.
            if attempt == 0 {
                #expect(firstStart.duration(to: .now) >= .seconds(9))
            } else {
                #expect(start.duration(to: .now) < .seconds(2))
            }
        }
        #expect(roots == 0)
    }

    @Test(.enabled(if: !Self.isSnapshotRuntime))
    func test_firstFrame_unsupportedRuntime_failsBeforeBuildingRoot() async throws {
        var roots = 0
        do {
            _ = try await SnapshotWindow.firstFrame(variant: SnapshotVariant(language: .english, textSize: .large)) { _ in
                roots += 1
                return SnapshotRoot(controller: UIViewController(), tabBar: .none)
            }
            Issue.record("An unsupported runtime must fail")
        } catch {
            #expect(String(describing: error).contains("Snapshots require the iOS 27.0 simulator"))
            #expect(String(describing: error).contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
        #expect(roots == 0)
    }

    @Test(.enabled(if: Locale.preferredLanguages.first?.hasPrefix("ru") == true))
    func test_capture_bundleLanguageMismatch_throwsBeforeRoot() async throws {
        #expect(Bundle.main.preferredLocalizations.first == "en")
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
                testName: "test_bundleLanguage",
                filePath: #filePath,
                sourceLocation: #_sourceLocation
            ) { _ in
                roots += 1
                return SnapshotRoot(controller: UIViewController(), tabBar: .none)
            }
            Issue.record("A mismatching main bundle language must fail")
        } catch {
            #expect(String(describing: error).contains("Snapshot language must be en or ru and match the host localization"))
            #expect(String(describing: error).contains("process: ru, bundle: en"))
        }
        #expect(roots == 0)
        let journal = try String(contentsOf: artifacts.appendingPathComponent("snapshots.tsv"), encoding: .utf8)
        let row = "test_bundleLanguage.ru-large\t"
            + "SnapshotWindowEnvironmentTests/test_bundleLanguage.ru-large.png\tfirst\terror\n"
        #expect(journal.contains(row))
    }
}
