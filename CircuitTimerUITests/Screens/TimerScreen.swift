import UITestContract
import XCTest

/// The full-screen timer. Its clock never advances in a scenario, so the screen holds still.
@MainActor
struct TimerScreen: Screen {
    let app: XCUIApplication

    private var closeButton: XCUIElement { app.buttons[AccessibilityID.Timer.close] }
    /// The card reads as one element, which XCUITest lists as no particular type.
    private var currentStage: XCUIElement { app.descendants(matching: .any)[AccessibilityID.Timer.currentStage] }

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        closeButton.waitUntilHittable("The timer's Close button", file: file, line: line)
    }

    /// The current stage as VoiceOver reads it, such as "Get ready, Starting in 3".
    @discardableResult
    func assertCurrentStage(_ spoken: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        currentStage.waitUntilValue("The current stage", is: spoken, file: file, line: line)
        return self
    }

    /// Asks to finish the workout: "Finish" leaves the timer, "No" stays.
    func tapClose(file: StaticString = #filePath, line: UInt = #line) -> AlertScreen<Self> {
        closeButton
            .waitUntilHittable("The timer's Close button", file: file, line: line)
            .tap()
        return AlertScreen(app, title: "Finish", file: file, line: line)
    }
}
