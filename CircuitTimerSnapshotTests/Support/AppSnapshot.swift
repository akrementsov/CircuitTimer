@testable import AppFeature

import ComposableArchitecture
import SnapshotCapture
import SwiftUI
import Testing
import UIKit

@MainActor
func assertAppSnapshot(
    textSize: SnapshotTextSize,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    state: (SnapshotLanguage) -> AppFeature.State
) async throws {
    let testName = function.description.prefix { $0 != "(" }
    try await assertFirstFrameSnapshot(
        textSize: textSize,
        testName: String(testName),
        filePath: filePath,
        sourceLocation: SourceLocation(fileID: fileID.description, filePath: filePath.description, line: Int(line), column: Int(column))
    ) { variant in
        try withDependencies(SnapshotDependencies.prepare) {
            let appState = state(variant.language)
            guard appState.destination == nil, appState.path.allSatisfy({
                if case let .editor(editor) = $0 { editor.destination == nil } else { true }
            }) else {
                throw AppSnapshotFailure()
            }
            let tabBar: TabBarExpectation
            switch appState.selectedTab {
                case .workouts:
                    tabBar = appState.path.isEmpty ? .shown(selectedStackDepth: 1) : .hidden(selectedStackDepth: appState.path.count + 1)
                case .settings:
                    tabBar = .shown(selectedStackDepth: appState.settings.path.count + 1)
            }
            let store = Store(initialState: appState) { AppFeature() }
            let controller = UIHostingController(
                rootView: AppView(store: store)
                    .environment(\.locale, variant.locale)
                    .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
                    .preferredColorScheme(.dark)
            )
            return SnapshotRoot(controller: controller, tabBar: tabBar)
        }
    }
}

private struct AppSnapshotFailure: Error, CustomStringConvertible {
    var description: String {
        "The timer's cover does not draw in the first frame; draw the timer with assertTimerSnapshot. "
            + "Alerts and dialogs are not supported yet."
    }
}
