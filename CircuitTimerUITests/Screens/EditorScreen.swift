import UITestContract
import XCTest

/// The workout screen: a new or edited draft, or a saved workout with Start.
@MainActor
struct EditorScreen: Screen {
    let app: XCUIApplication

    private var backButton: XCUIElement { app.buttons[AccessibilityID.Editor.back] }
    private var nameField: XCUIElement { app.textFields[AccessibilityID.Editor.name] }
    private var saveButton: XCUIElement { app.buttons[AccessibilityID.Editor.save] }
    private var startButton: XCUIElement { app.buttons[AccessibilityID.Editor.start] }

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        backButton.waitUntilHittable("The workout screen's Back button", file: file, line: line)
    }

    /// Types the name and ends with Return, which closes the keyboard: the panel with Save rides above the keyboard
    /// and would cover the stages a later step taps on a small screen.
    func typeName(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        nameField
            .waitUntilHittable("The workout's name field", file: file, line: line)
            .tap()
        nameField.typeText(name + "\n")
        app.keyboards.firstMatch.waitUntilGone("The keyboard", file: file, line: line)
        return self
    }

    /// Types digits into a stage's MM:SS duration, such as "0045" for 45 seconds.
    func setDuration(
        _ digits: String,
        in section: StageSection,
        stage index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Self {
        let field = app.textFields[AccessibilityID.Editor.stageDuration(section, index)]
        field
            .waitUntilHittable("The duration of \(section.rawValue) stage \(index)", file: file, line: line)
            .tap()
        field.typeText(digits)
        return self
    }

    /// Saves the draft and waits until the screen shows the saved workout.
    func tapSave(file: StaticString = #filePath, line: UInt = #line) -> Self {
        saveButton
            .waitUntilHittable("The Save button", file: file, line: line)
            .tap()
        startButton.waitUntilHittable("The saved workout's Start button", file: file, line: line)
        return self
    }

    func tapStart(file: StaticString = #filePath, line: UInt = #line) -> TimerScreen {
        startButton
            .waitUntilHittable("The Start button", file: file, line: line)
            .tap()
        return TimerScreen(app, file: file, line: line)
    }

    func tapBack(file: StaticString = #filePath, line: UInt = #line) -> WorkoutListScreen {
        backButton
            .waitUntilHittable("The Back button", file: file, line: line)
            .tap()
        return WorkoutListScreen(app, file: file, line: line)
    }

    @discardableResult
    func assertTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.navigationBars.staticTexts[title].waitUntilExists("The title \"\(title)\"", file: file, line: line)
        return self
    }
}
