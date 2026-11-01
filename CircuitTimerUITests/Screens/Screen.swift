import XCTest

/// A screen of the app as a test drives it. Creating one waits until it shows; each action returns the screen the
/// user lands on. Element queries stay private to the screen, and every action and check takes the test's `file`
/// and `line`, so a failure points at the test's step.
@MainActor
protocol Screen {
    var app: XCUIApplication { get }

    init(_ app: XCUIApplication, file: StaticString, line: UInt)
}

/// How long a drag presses a row before it moves. A row lifts 0.35 s after touch-down, and a stage row pressed on its
/// name at 0.50–0.57 s, while UIKit settles whether the name field's text drag begins (iOS 17.5 and 27.0). A busy main
/// thread lifts it later still, and a drag that starts first moves nothing: the press fails, and the field's loupe
/// takes it.
let rowLiftHold: TimeInterval = 1.5
