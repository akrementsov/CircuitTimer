@testable import WorkoutTimerFeature

import BackgroundExecution
import BackgroundNotifications
import ComposableArchitecture
import Foundation
import SnapshotCapture
import SwiftUI
import Testing
import UIKit
import WorkoutActivity
import WorkoutHealth
import WorkoutStorage

/// The timer's dependencies in a snapshot: none of them reaches audio, the disk, the idle timer, notifications,
/// Live Activities or Health. `make lint` checks only `AppScenario.prepare`, so a new client the timer reads also
/// needs a line here.
enum TimerSnapshotDependencies {
    /// The moment every timer state is settled at, and what `date` returns.
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func prepare(_ dependencies: inout DependencyValues, locale: Locale) {
        SnapshotDependencies.prepare(&dependencies)
        dependencies.workoutRunRecord = .previewValue
        dependencies.backgroundNotifications = .previewValue
        dependencies.liveActivity = .previewValue
        dependencies.workoutHealth = .previewValue
        dependencies.cues = .previewValue
        dependencies.timerSession = .previewValue
        dependencies.backgroundTask = .previewValue
        dependencies.date = .constant(now)
        // Only the language of notification texts, which no frame shows.
        dependencies.preferredLocales = [locale]
        dependencies.uuid = .incrementing
        dependencies.dismiss = DismissEffect {}
    }
}

/// Draws `WorkoutTimerStack` as the window's root: the presented cover does not draw in the first frame.
@MainActor
func assertTimerSnapshot(
    textSize: SnapshotTextSize,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    state: (SnapshotLanguage) -> WorkoutTimerFeature.State
) async throws {
    let testName = function.description.prefix { $0 != "(" }
    try await assertFirstFrameSnapshot(
        textSize: textSize,
        testName: String(testName),
        filePath: filePath,
        sourceLocation: SourceLocation(fileID: fileID.description, filePath: filePath.description, line: Int(line), column: Int(column))
    ) { variant in
        try withDependencies {
            TimerSnapshotDependencies.prepare(&$0, locale: variant.locale)
        } operation: {
            let timerState = state(variant.language)
            guard timerState.destination == nil else {
                throw TimerSnapshotFailure.presentedDestination
            }
            guard timerState.hasAppearedForSnapshot else {
                throw TimerSnapshotFailure.notAppeared
            }
            let store = Store(initialState: timerState) { WorkoutTimerFeature() }
            let controller = UIHostingController(
                rootView: WorkoutTimerStack(store: store)
                    // Pinned: the host's own phase sequence could reset the signal baseline or restart the countdown's
                    // audio preparation, and either changes the frame.
                    .environment(\.scenePhase, .active)
                    .environment(\.locale, variant.locale)
                    .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
                    .preferredColorScheme(.dark)
            )
            return SnapshotRoot(controller: controller, tabBar: .none)
        }
    }
}

private enum TimerSnapshotFailure: Error, CustomStringConvertible {
    case presentedDestination
    case notAppeared

    var description: String {
        switch self {
            case .presentedDestination:
                "The timer's close dialog does not draw in the first frame; alerts and dialogs are not supported yet."
            case .notAppeared:
                "Build the timer state with the factories in Support/WorkoutTimerFeature+SnapshotStates.swift, which "
                    + "settle it as the screen shows it once it has appeared; otherwise its appearance changes the first frame."
        }
    }
}
