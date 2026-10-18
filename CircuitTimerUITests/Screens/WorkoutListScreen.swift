import UITestContract
import XCTest

/// The Workouts tab's root: the list, or the empty state.
@MainActor
struct WorkoutListScreen: Screen {
    let app: XCUIApplication

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
}
