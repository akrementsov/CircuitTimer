import XCTest

/// A screen of the app as a test drives it. Creating one waits until it shows; each action returns the screen the
/// user lands on. Element queries stay private to the screen, and every action and check takes the test's `file`
/// and `line`, so a failure points at the test's step.
@MainActor
protocol Screen {
    var app: XCUIApplication { get }

    init(_ app: XCUIApplication, file: StaticString, line: UInt)
}
