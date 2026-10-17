import XCTest

/// A screen of the app as a test drives it. Creating one waits until it shows; each action returns the screen the
/// user lands on. Element queries stay private to the screen, and every action and check takes the test's `file`
/// and `line`, so a failure points at the test's step.
@MainActor
protocol Screen {
    var app: XCUIApplication { get }

    init(_ app: XCUIApplication, file: StaticString, line: UInt)
}

/// A system alert over `Source`. A choice waits until the alert has gone and the next screen shows.
@MainActor
struct AlertScreen<Source: Screen> {
    let app: XCUIApplication
    private let alert: XCUIElement

    init(_ app: XCUIApplication, title: String, file: StaticString, line: UInt) {
        self.app = app
        alert = app.alerts[title].waitUntilExists("The alert \"\(title)\"", file: file, line: line)
    }

    /// Chooses a button that keeps the user on the screen under the alert.
    @discardableResult
    func tap(_ button: String, file: StaticString = #filePath, line: UInt = #line) -> Source {
        tap(button, landingOn: Source.self, file: file, line: line)
    }

    @discardableResult
    func tap<Next: Screen>(
        _ button: String,
        landingOn _: Next.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Next {
        alert.buttons[button]
            .waitUntilHittable("The alert's button \"\(button)\"", file: file, line: line)
            .tap()
        alert.waitUntilGone("The alert", file: file, line: line)
        return Next(app, file: file, line: line)
    }
}
