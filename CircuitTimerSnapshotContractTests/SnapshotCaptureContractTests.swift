@testable import AppFeature
@testable import SnapshotCapture
@testable import WorkoutEditorFeature
@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import os
import SwiftUI
import Testing
import UIKit
import WorkoutDomain

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SnapshotCaptureContractTests {
    @Test(arguments: ["never", "failed"])
    func test_capture_firstFrameWithinBounds_preservesReference(mode: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        try await run.seedReference(withNoise: true)
        let before = try Data(contentsOf: run.reference.url)
        var controllers: [SnapshotContractController] = []
        try await run.capture(mode: mode) {
            let controller = SnapshotContractController()
            controllers.append(controller)
            return SnapshotRoot(controller: controller, tabBar: .none)
        }
        #expect(controllers.count == 1)
        #expect(try Data(contentsOf: run.reference.url) == before)
        #expect(try run.rows() == [run.row(attempt: "first", outcome: "passed")])
        try expectDetached(controllers)
    }

    @Test(arguments: ["never", "failed"])
    func test_capture_firstMismatchSecondWithinBounds_usesFreshRootAndPreservesReference(mode: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        try await run.seedReference(withNoise: true)
        let before = try Data(contentsOf: run.reference.url)
        var controllers: [SnapshotContractController] = []
        try await run.capture(mode: mode) {
            let controller = SnapshotContractController(value: controllers.isEmpty ? 160 : 64)
            controllers.append(controller)
            return SnapshotRoot(controller: controller, tabBar: .none)
        }
        #expect(controllers.count == 2)
        #expect(controllers[0] !== controllers[1])
        #expect(try Data(contentsOf: run.reference.url) == before)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "passed")])
        try expectDetached(controllers)
    }

    @Test(arguments: [false, true])
    func test_capture_neverMissingOrMismatching_recordsIssueWithoutWritingReference(existing: Bool) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        if existing { try await run.seedReference() }
        let before = existing ? try Data(contentsOf: run.reference.url) : nil
        var mounts = 0
        let issues = OSAllocatedUnfairLock(initialState: 0)
        try await withKnownIssue(
            "The comparison must report its caller's source location",
            {
                try await run.capture {
                    mounts += 1
                    return SnapshotRoot(controller: SnapshotContractController(value: 160), tabBar: .none)
                }
            },
            matching: { issue in
                guard issue.sourceLocation == SnapshotContractRun.location else { return false }
                issues.withLock { $0 += 1 }
                return true
            }
        )
        #expect(issues.withLock { $0 } == 1)
        #expect(mounts == 2)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "failed")])
        if let before {
            #expect(try Data(contentsOf: run.reference.url) == before)
        } else {
            #expect(!FileManager.default.fileExists(atPath: run.reference.url.path))
        }
        let actual = run.artifacts.appendingPathComponent("SnapshotCaptureContractTests/\(run.key).png")
        #expect(FileManager.default.fileExists(atPath: actual.path) == existing)
    }

    @Test(arguments: [false, true])
    func test_capture_recordMissingOrMismatching_confirmsSecondFrameBytes(existing: Bool) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        if existing { try await run.seedReference(value: 160) }
        let expectedFrame = try await SnapshotWindow.firstFrame(variant: run.variant) { _ in
            SnapshotRoot(controller: SnapshotContractController(), tabBar: .none)
        }
        let expectedData = SnapshotImageComparison.strategy.diffing.toData(expectedFrame.image)
        var mounts = 0
        let issues = OSAllocatedUnfairLock(initialState: 0)
        try await withKnownIssue(
            "Recording reports an issue for the newly written reference",
            {
                try await run.capture(mode: "failed") {
                    mounts += 1
                    return SnapshotRoot(controller: SnapshotContractController(value: mounts == 1 ? 128 : 64), tabBar: .none)
                }
            },
            matching: { issue in
                guard issue.sourceLocation == SnapshotContractRun.location else { return false }
                issues.withLock { $0 += 1 }
                return true
            }
        )
        #expect(issues.withLock { $0 } == 1)
        #expect(mounts == 2)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "recorded")])
        #expect(try Data(contentsOf: run.reference.url) == expectedData)
    }

    @Test(arguments: [false, true])
    func test_capture_failedReferenceOrArtifactWrite_isNotConfirmedRecording(existing: Bool) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        if existing {
            try await run.seedReference(value: 160)
            try FileManager.default.createDirectory(at: run.artifacts, withIntermediateDirectories: true)
            try Data().write(to: run.artifacts.appendingPathComponent("SnapshotCaptureContractTests"))
        } else {
            try FileManager.default.createDirectory(
                at: run.reference.directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: run.reference.directory)
        }
        let before = existing ? try Data(contentsOf: run.reference.url) : nil
        try await withKnownIssue(
            "A failed write must remain a failed comparison",
            {
                try await run.capture(mode: "failed") { SnapshotRoot(controller: SnapshotContractController(), tabBar: .none) }
            },
            matching: { $0.sourceLocation == SnapshotContractRun.location }
        )
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "failed")])
        if let before {
            #expect(try Data(contentsOf: run.reference.url) == before)
        } else {
            #expect(!FileManager.default.fileExists(atPath: run.reference.url.path))
        }
    }

    @Test(arguments: [false, true])
    func test_capture_journalFailureAfterComparison_throwsCombinedError(mismatch: Bool) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        try await run.seedReference()
        try Data().write(to: run.artifacts)
        do {
            try await run.capture {
                SnapshotRoot(controller: SnapshotContractController(value: mismatch ? 160 : 64), tabBar: .none)
            }
            Issue.record("A failed journal must not produce a successful capture")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Capture journal also failed:"))
            #expect(!message.contains("Snapshot does not match"))
        }
    }

    @Test
    func test_capture_originalErrorAndJournalFailure_keepsBothErrors() async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        do {
            try await run.capture(mode: "unsupported", artifacts: "") {
                Issue.record("Invalid recording mode must fail before makeRoot")
                return SnapshotRoot(controller: SnapshotContractController(), tabBar: .none)
            }
            Issue.record("Capture unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("Unsupported SNAPSHOT_TESTING_RECORD"))
            #expect(String(describing: error).contains("Capture journal also failed:"))
            #expect(String(describing: error).contains("SNAPSHOT_ARTIFACTS must not be empty"))
        }
    }

    @Test(arguments: ["mode", "name", "reference", "root"])
    func test_capture_errorBeforeMount_isThrownAndJournaledOnce(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        if input == "reference" {
            try FileManager.default.createDirectory(at: run.reference.directory, withIntermediateDirectories: true)
            try Data("not PNG".utf8).write(to: run.reference.url)
        }
        var mounts = 0
        do {
            try await run.capture(mode: input == "mode" ? "invalid" : "never", testName: input == "name" ? "invalid/name" : nil) {
                mounts += 1
                throw SnapshotContractError.root
            }
            Issue.record("Invalid capture must throw")
        } catch {
            let message = String(describing: error)
            switch input {
                case "mode": #expect(message.contains("Unsupported SNAPSHOT_TESTING_RECORD"))
                case "name": #expect(message.contains("would rewrite the snapshot name"))
                case "reference": #expect(message.contains("Invalid reference at"))
                default: #expect(error as? SnapshotContractError == .root)
            }
        }
        #expect(mounts == (input == "root" ? 1 : 0))
        let rows = try run.rows()
        #expect(rows.count == 1)
        #expect(rows[0].hasSuffix("\tfirst\terror"))
        #expect(!FileManager.default.fileExists(atPath: run.artifacts.appendingPathComponent("SnapshotCaptureContractTests").path))
    }

    @Test(arguments: ["missing-tab", "missing-navigation", "depth", "hidden"])
    func test_capture_invalidTabStack_throwsAndDetachesWindow(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        let controller = SnapshotContractController()
        let tab = UITabBarController()
        tab.viewControllers = input == "missing-navigation" ? [controller] : [UINavigationController(rootViewController: controller)]
        if input == "hidden", #available(iOS 18, *) { tab.setTabBarHidden(true, animated: false) }
        do {
            try await run.capture {
                SnapshotRoot(
                    controller: input == "missing-tab" ? controller : tab,
                    tabBar: .shown(selectedStackDepth: input == "depth" ? 2 : 1)
                )
            }
            Issue.record("Invalid tab stack must fail")
        } catch {
            let message = String(describing: error)
            switch input {
                case "depth": #expect(message.contains("Expected selected stack depth 2; got 1"))
                case "hidden": #expect(message.contains("The tab bar must be shown"))
                default: #expect(message.contains("no selected tab navigation stack"))
            }
        }
        #expect(try run.rows() == [run.row(attempt: "first", outcome: "error")])
        try expectDetached([controller])
    }

    @Test(arguments: [0, 1, 2])
    func test_capture_cancellation_cleansWindowAndPreservesCancellation(mount: Int) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        if mount == 2 { try await run.seedReference(value: 160) }
        var controllers: [SnapshotContractController] = []
        defer { for controller in controllers { controller.onLayout = nil } }
        await run.withEnvironment {
            var cancel: (() -> Void)?
            let task = Task { @MainActor in
                if mount == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                try await run.capture {
                    let controller = SnapshotContractController()
                    controllers.append(controller)
                    if controllers.count == mount { controller.onLayout = { cancel?() } }
                    return SnapshotRoot(controller: controller, tabBar: .none)
                }
            }
            cancel = { task.cancel() }
            do {
                try await task.value
                Issue.record("A cancelled capture must not succeed")
            } catch { #expect(error is CancellationError) }
            cancel = nil
        }
        #expect(controllers.count == mount)
        #expect(try run.rows() == [run.row(attempt: mount == 2 ? "second" : "first", outcome: "error")])
        try expectDetached(controllers)
    }

    @Test(arguments: ["alert", "resume", "permission", "timer", "editor"])
    func test_appSnapshot_presentedDestination_throwsWithoutMounting(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let windows = scene.windows.map(ObjectIdentifier.init)
        await run.withEnvironment {
            do {
                try await assertAppSnapshot(textSize: .large, function: "test_rejectedState()") { language in
                    let workout = SnapshotFixtures.editorWorkout(language: language)
                    var state = AppFeature.State.list([workout])
                    switch input {
                        case "alert": state.destination = .alert(AlertState { TextState("Probe") })
                        case "resume": state.destination = .resumeRun(AlertState { TextState("Probe") })
                        case "permission": state.destination = .permissionStalled(AlertState { TextState("Probe") })
                        case "timer":
                            state.destination = .timer(.init(
                                id: workout.id,
                                workoutID: workout.id,
                                title: workout.name,
                                workoutName: workout.name,
                                schedule: WorkoutSchedule(workout: workout)
                            ))
                        default:
                            var editor = WorkoutEditorFeature.State(viewing: workout)
                            editor.destination = .saveFailedAlert(AlertState { TextState("Probe") })
                            state.path.append(.editor(editor))
                    }
                    return state
                }
                Issue.record("Presented destinations must be rejected")
            } catch {
                #expect(String(describing: error).contains("The timer's cover does not draw in the first frame"))
            }
        }
        #expect(scene.windows.map(ObjectIdentifier.init) == windows)
        let rows = try run.rows()
        #expect(rows.count == 1)
        #expect(rows[0].hasSuffix("\tfirst\terror"))
    }

    @Test
    func test_appSnapshot_remount_buildsFreshStateAndStore() async throws {
        let run = SnapshotContractRun(testName: "test_appSnapshot_remount_buildsFreshStateAndStore")
        defer { run.cleanUp() }
        try await run.withEnvironment(mode: "failed") {
            try await withKnownIssue(
                "Seed the app reference for the second mount",
                {
                    try await assertAppSnapshot(textSize: .large, function: #function, line: 1, column: 1) { language in
                        .list(SnapshotFixtures.workouts(language: language), hiddenRecordCount: 2)
                    }
                },
                matching: { $0.sourceLocation == SnapshotContractRun.location }
            )
        }
        let before = try Data(contentsOf: run.reference.url)
        try FileManager.default.removeItem(at: run.artifacts)
        var states = 0
        try await run.withEnvironment {
            try await assertAppSnapshot(textSize: .large, function: #function, line: 1, column: 1) { language in
                states += 1
                return .list(states == 1 ? [] : SnapshotFixtures.workouts(language: language), hiddenRecordCount: 2)
            }
        }
        #expect(states == 2)
        #expect(try Data(contentsOf: run.reference.url) == before)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "passed")])
    }

    @Test(arguments: ["missing", "unknown", "different", "category"])
    func test_capture_invalidProcessSize_failsBeforeRoot(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        var mounts = 0
        await run.withEnvironment {
            switch input {
                case "missing": unsetenv("SNAPSHOT_TEXT_SIZE")
                case "unknown": setenv("SNAPSHOT_TEXT_SIZE", "unknown", 1)
                default: setenv("SNAPSHOT_TEXT_SIZE", "ax5", 1)
            }
            do {
                try await assertFirstFrameSnapshot(
                    textSize: input == "category" ? .ax5 : .large,
                    testName: run.testName,
                    filePath: #filePath,
                    sourceLocation: SnapshotContractRun.location
                ) { _ in
                    mounts += 1
                    return SnapshotRoot(controller: SnapshotContractController(), tabBar: .none)
                }
                Issue.record("Wrong process size must fail")
            } catch {
                #expect(String(describing: error).contains("Snapshot text size must match its process"))
            }
        }
        #expect(mounts == 0)
        let rows = try run.rows()
        #expect(rows.count == 1)
        #expect(rows[0].hasSuffix("\tfirst\terror"))
    }

    @Test
    func test_capture_rootChangesRaster_throwsAndDetaches() async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        let controller = SnapshotContractController()
        controller.onLayout = { [weak controller] in controller?.view.window?.bounds.size.width = 400 }
        defer { controller.onLayout = nil }
        do {
            try await run.capture { SnapshotRoot(controller: controller, tabBar: .none) }
            Issue.record("A changed raster must not produce a reference")
        } catch {
            #expect(String(describing: error).contains("raster must be 1206×2622 px"))
            #expect(String(describing: error).contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
        #expect(try run.rows() == [run.row(attempt: "first", outcome: "error")])
        try expectDetached([controller])
    }

    @Test(arguments: [false, true])
    func test_capture_drawHierarchyFalse_remountsOrThrows(bothMounts: Bool) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        try await run.seedReference()
        var controllers: [SnapshotContractController] = []
        var frames = 0
        do {
            try await run.withEnvironment {
                try await assertFirstFrameSnapshot(
                    textSize: .large,
                    testName: run.testName,
                    filePath: #filePath,
                    sourceLocation: SnapshotContractRun.location,
                    firstFrame: { variant in
                        let frame = try await SnapshotWindow.firstFrame(variant: variant) { _ in
                            let controller = SnapshotContractController()
                            controllers.append(controller)
                            return SnapshotRoot(controller: controller, tabBar: .none)
                        }
                        frames += 1
                        return (frame.image, frames > 1 && !bothMounts)
                    }
                )
            }
            #expect(!bothMounts)
        } catch {
            #expect(bothMounts)
            #expect(String(describing: error).contains("drawHierarchy failed on the second mount"))
        }
        #expect(frames == 2)
        #expect(controllers.count == 2)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: bothMounts ? "error" : "passed")])
        try expectDetached(controllers)
    }

    @Test(arguments: ["size", "scale", "safe-top", "safe-bottom", "safe-left", "safe-right", "raster"])
    func test_capture_invalidViewport_measurementFailureIsJournaled(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        do {
            try await run.withEnvironment {
                try await assertFirstFrameSnapshot(
                    textSize: .large,
                    testName: run.testName,
                    filePath: #filePath,
                    sourceLocation: SnapshotContractRun.location,
                    firstFrame: { _ in
                        switch input {
                            case "size": try SnapshotViewport.validateScene(size: CGSize(width: 401, height: 874), scale: 3)
                            case "scale": try SnapshotViewport.validateScene(size: CGSize(width: 402, height: 874), scale: 2)
                            case "safe-top": try SnapshotViewport.validateSafeArea(UIEdgeInsets(top: 61, left: 0, bottom: 34, right: 0))
                            case "safe-bottom": try SnapshotViewport.validateSafeArea(UIEdgeInsets(top: 62, left: 0, bottom: 33, right: 0))
                            case "safe-left": try SnapshotViewport.validateSafeArea(UIEdgeInsets(top: 62, left: 1, bottom: 34, right: 0))
                            case "safe-right": try SnapshotViewport.validateSafeArea(UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 1))
                            default:
                                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                                let context = try #require(CGContext(
                                    data: nil,
                                    width: 1206,
                                    height: 2621,
                                    bitsPerComponent: 8,
                                    bytesPerRow: 1206 * 4,
                                    space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                ))
                                try SnapshotViewport.validateRaster(context.makeImage())
                        }
                        throw SnapshotContractError.unexpectedMeasurementSuccess
                    }
                )
            }
            Issue.record("An invalid viewport must fail")
        } catch {
            let message = String(describing: error)
            let expected = input.hasPrefix("safe-") ? "safe area insets of 62/34 pt; got" :
                input == "raster" ? "raster must be 1206×2622 px" : "402×874 pt scene at 3x"
            #expect(message.contains(expected))
            #expect(message.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
        #expect(try run.rows() == [run.row(attempt: "first", outcome: "error")])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27))
    func test_capture_unsupportedRuntime_throwsAndJournals() async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        var roots = 0
        do {
            try await run.capture {
                roots += 1
                return SnapshotRoot(controller: SnapshotContractController(), tabBar: .none)
            }
            Issue.record("An unsupported runtime must fail before mounting")
        } catch {
            #expect(String(describing: error).contains("Snapshots require the iOS 27.0 simulator"))
            #expect(String(describing: error).contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
        #expect(roots == 0)
        #expect(try run.rows() == [run.row(attempt: "first", outcome: "error")])
    }

    private func expectDetached(_ controllers: [SnapshotContractController]) throws {
        for controller in controllers {
            let window = try #require(controller.capturedWindow)
            #expect(window.isHidden)
            #expect(window.rootViewController == nil)
            #expect(window.windowScene == nil)
            if let previous = controller.previousKey { #expect(previous.isKeyWindow) }
        }
    }
}

// The timer's entry; an extension keeps the suite's body within SwiftLint's type length.
extension SnapshotCaptureContractTests {
    @Test(arguments: ["factory", "start"])
    func test_timerSnapshot_closeDialog_throwsWithoutMounting(input: String) async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let windows = scene.windows.map(ObjectIdentifier.init)
        var states = 0
        await run.withEnvironment {
            do {
                try await assertTimerSnapshot(textSize: .large, function: "test_rejectedState()") { language in
                    states += 1
                    let workout = SnapshotFixtures.editorWorkout(language: language)
                    var state = input == "factory" ? .paused(workout) : AppFeature().timerState(for: workout)
                    state.destination = .closeConfirmation(AlertState { TextState("Probe") })
                    return state
                }
                Issue.record("The close dialog must be rejected")
            } catch {
                #expect(String(describing: error).contains("The timer's close dialog does not draw in the first frame"))
            }
        }
        #expect(states == 1)
        #expect(scene.windows.map(ObjectIdentifier.init) == windows)
        let rows = try run.rows()
        #expect(rows.count == 1)
        #expect(rows[0].hasSuffix("\tfirst\terror"))
    }

    @Test
    func test_timerSnapshot_stateNotAppeared_throwsWithoutMounting() async throws {
        let run = SnapshotContractRun()
        defer { run.cleanUp() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let windows = scene.windows.map(ObjectIdentifier.init)
        var states = 0
        await run.withEnvironment {
            do {
                try await assertTimerSnapshot(textSize: .large, function: "test_rejectedState()") { language in
                    states += 1
                    return AppFeature().timerState(for: SnapshotFixtures.editorWorkout(language: language))
                }
                Issue.record("A state that has not appeared must be rejected")
            } catch {
                #expect(String(describing: error).contains("Build the timer state with the factories"))
            }
        }
        #expect(states == 1)
        #expect(scene.windows.map(ObjectIdentifier.init) == windows)
        let rows = try run.rows()
        #expect(rows.count == 1)
        #expect(rows[0].hasSuffix("\tfirst\terror"))
    }

    @Test
    func test_timerSnapshot_remount_buildsFreshState() async throws {
        let run = SnapshotContractRun(testName: "test_timerSnapshot_remount_buildsFreshState")
        defer { run.cleanUp() }
        try await run.withEnvironment(mode: "failed") {
            try await withKnownIssue(
                "Seed the timer reference for the second mount",
                {
                    try await assertTimerSnapshot(textSize: .large, function: #function, line: 1, column: 1) { language in
                        .finished(SnapshotFixtures.editorWorkout(language: language))
                    }
                },
                matching: { $0.sourceLocation == SnapshotContractRun.location }
            )
        }
        let before = try Data(contentsOf: run.reference.url)
        try FileManager.default.removeItem(at: run.artifacts)
        var states = 0
        try await run.withEnvironment {
            try await assertTimerSnapshot(textSize: .large, function: #function, line: 1, column: 1) { language in
                states += 1
                let workout = SnapshotFixtures.editorWorkout(language: language)
                return states == 1 ? .paused(workout) : .finished(workout)
            }
        }
        #expect(states == 2)
        #expect(try Data(contentsOf: run.reference.url) == before)
        #expect(try run.rows() == [run.row(attempt: "second", outcome: "passed")])
    }

    @Test
    func test_timerSnapshotRoot_mounted_reportsAnActiveScene() async throws {
        let run = SnapshotContractRun()
        let phases = LockIsolated<[ScenePhase]>([])
        let store = withDependencies {
            TimerSnapshotDependencies.prepare(&$0, locale: run.variant.locale)
        } operation: {
            Store(initialState: .startCountdown(SnapshotFixtures.editorWorkout(language: .english))) {
                Reduce<WorkoutTimerFeature.State, WorkoutTimerFeature.Action> { _, action in
                    if case let .view(.scenePhaseChanged(phase)) = action { phases.withValue { $0.append(phase) } }
                    return .none
                }
                WorkoutTimerFeature()
            }
        }
        let root = timerSnapshotRoot(store, variant: run.variant)
        let frame = try await SnapshotWindow.firstFrame(variant: run.variant) { _ in root }
        #expect(frame.succeeded)
        #expect(root.controller.view.window == nil)
        #expect(phases.value == [.active])
        #expect(store.isSceneActive)
        #expect(!store.isInBackground)
        #expect(store.countdown?.remaining == 3)
        #expect(store.state.hasAppearedForSnapshot)
    }
}

private enum SnapshotContractError: Error { case root, unexpectedMeasurementSuccess }

@MainActor
private final class SnapshotContractController: UIViewController {
    var capturedWindow: UIWindow?
    var previousKey: UIWindow?
    var onLayout: (() -> Void)?
    private let value: UInt8

    init(value: UInt8 = 64) {
        self.value = value
        super.init(nibName: nil, bundle: nil)
        previousKey = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    required init?(coder: NSCoder) { fatalError("Use init(value:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let channel = CGFloat(value) / 255
        view.layer.backgroundColor = CGColor(srgbRed: channel, green: channel, blue: channel, alpha: 1)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let window = view.window { capturedWindow = window }
        onLayout?()
    }
}

@MainActor
private struct SnapshotContractRun {
    nonisolated static let location = SourceLocation(fileID: #fileID, filePath: #filePath, line: 1, column: 1)
    let testName: String

    init(testName: String = "test_capture_" + ProcessInfo.processInfo.globallyUniqueString.filter { $0.isLetter || $0.isNumber }) {
        self.testName = testName
    }
    let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
    var variant: SnapshotVariant { SnapshotVariant(language: .english, textSize: .large) }
    var key: String { "\(testName).en-large" }
    var reference: SnapshotReference { SnapshotReference(filePath: #filePath, testName: testName, variantName: "en-large") }

    func seedReference(value: UInt8 = 64, withNoise: Bool = false) async throws {
        let frame = try await SnapshotWindow.firstFrame(variant: variant) { _ in
            SnapshotRoot(controller: SnapshotContractController(value: value), tabBar: .none)
        }
        #expect(frame.succeeded)
        let image = withNoise ? try noisyImage(frame.image) : frame.image
        try FileManager.default.createDirectory(at: reference.directory, withIntermediateDirectories: true)
        try SnapshotImageComparison.strategy.diffing.toData(image).write(to: reference.url)
    }

    func capture(
        mode: String = "never",
        artifacts path: String? = nil,
        testName name: String? = nil,
        root: () throws -> SnapshotRoot
    ) async throws {
        try await withEnvironment(mode: mode, artifacts: path) {
            try await assertFirstFrameSnapshot(
                textSize: .large,
                testName: name ?? testName,
                filePath: #filePath,
                sourceLocation: Self.location,
                makeRoot: { _ in try root() }
            )
        }
    }

    func withEnvironment(mode: String = "never", artifacts path: String? = nil, operation: () async throws -> Void) async rethrows {
        let values = ["SNAPSHOT_TEXT_SIZE": "large", "SNAPSHOT_TESTING_RECORD": mode, "SNAPSHOT_ARTIFACTS": path ?? artifacts.path]
        let previous = ProcessInfo.processInfo.environment
        defer {
            for key in values.keys {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in values { setenv(key, value, 1) }
        try await operation()
    }

    func rows() throws -> [String] {
        try String(contentsOf: artifacts.appendingPathComponent("snapshots.tsv"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
    }

    func row(attempt: String, outcome: String) -> String {
        "\(key)\tSnapshotCaptureContractTests/\(key).png\t\(attempt)\t\(outcome)"
    }

    func cleanUp() {
        do {
            for url in [reference.url, artifacts] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: reference.directory.path) {
                let isDirectory = (try reference.directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                let isEmpty = isDirectory ? try FileManager.default.contentsOfDirectory(atPath: reference.directory.path).isEmpty : true
                if isEmpty {
                    try FileManager.default.removeItem(at: reference.directory)
                }
            }
        } catch { Issue.record(error) }
    }

    private func noisyImage(_ image: UIImage) throws -> UIImage {
        let raster = try #require(image.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: raster.width,
            height: raster.height,
            bitsPerComponent: 8,
            bytesPerRow: raster.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        bytes[0] += 1
        return UIImage(cgImage: try #require(context.makeImage()), scale: 3, orientation: .up)
    }
}
