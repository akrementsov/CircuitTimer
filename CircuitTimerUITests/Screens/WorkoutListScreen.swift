import UITestContract
import XCTest

/// The Workouts tab's root: the list, or the empty state.
@MainActor
struct WorkoutListScreen: Screen {
    let app: XCUIApplication

    // Mirrors DesignSystem's .m spacing token; the UI test target imports only UITestContract.
    private static let cardGap: CGFloat = 12

    private var addButton: XCUIElement { app.buttons[AccessibilityID.WorkoutList.add] }
    private var emptyState: XCUIElement { app.staticTexts[AccessibilityID.WorkoutList.empty] }

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        addButton.waitUntilHittable("The workout list's Add button", file: file, line: line)
    }

    func tapAdd(file: StaticString = #filePath, line: UInt = #line) -> EditorScreen {
        addButton
            .waitUntilHittable("The workout list's Add button", file: file, line: line)
            .tap()
        return EditorScreen(app, file: file, line: line)
    }

    func tapSettings(file: StaticString = #filePath, line: UInt = #line) -> SettingsScreen {
        app.tabBars.buttons["Settings"]
            .waitUntilHittable("The Settings tab", file: file, line: line)
            .tap()
        return SettingsScreen(app, file: file, line: line)
    }

    func openWorkout(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> EditorScreen {
        row(name, file: file, line: line).tap()
        return EditorScreen(app, file: file, line: line)
    }

    @discardableResult
    func assertIsEmpty(file: StaticString = #filePath, line: UInt = #line) -> Self {
        emptyState.waitUntilExists("The empty list's message", file: file, line: line)
        return self
    }

    /// The workout shows once, with its total time as VoiceOver reads it, such as "2 minutes".
    @discardableResult
    func assertHasWorkout(
        _ name: String,
        duration: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Self {
        let workout = row(name, file: file, line: line)
        if let duration {
            workout.waitUntilValue("The total time of \"\(name)\"", is: duration, file: file, line: line)
        }
        return self
    }

    private func row(_ name: String, file: StaticString, line: UInt) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@", name))
            .assertSingle("The workout \"\(name)\"", file: file, line: line)
    }

    func moveWorkout(_ name: String, onto destination: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        let source = row(name, file: file, line: line)
        let target = row(destination, file: file, line: line)
        source.press(forDuration: 0.6, thenDragTo: target, withVelocity: .fast, thenHoldForDuration: 0)
        return self
    }

    func moveWorkoutToBottom(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        let source = row(name, file: file, line: line)
            .waitUntilHittable("The workout to move", file: file, line: line)
        let edge = app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: edge, withVelocity: .fast, thenHoldForDuration: 3)
        return self
    }

    @discardableResult
    func assertOrder(_ names: [String], file: StaticString = #filePath, line: UInt = #line) -> Self {
        for index in names.indices.dropFirst() {
            let above = row(names[index - 1], file: file, line: line)
            row(names[index], file: file, line: line).waitUntilBelow(
                above,
                gap: Self.cardGap,
                description: "\"\(names[index])\" follows \"\(names[index - 1])\"",
                file: file,
                line: line
            )
        }
        return self
    }
}
