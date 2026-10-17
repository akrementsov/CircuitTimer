import XCTest

/// How long a screen waits for the app before it fails the test.
private let screenTimeout: TimeInterval = 10

/// Waits that fail the test at the line of the test, not of the screen: screens pass their caller's `file` and `line`.
@MainActor
extension XCUIElement {
    @discardableResult
    func waitUntilExists(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        if !waitForExistence(timeout: screenTimeout) {
            XCTFail("\(description) did not appear within \(Int(screenTimeout)) s", file: file, line: line)
        }
        return self
    }

    @discardableResult
    func waitUntilHittable(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        if !wait(for: \.isHittable, toEqual: true, timeout: screenTimeout) {
            XCTFail("\(description) could not be tapped within \(Int(screenTimeout)) s", file: file, line: line)
        }
        return self
    }

    func waitUntilGone(_ description: String, file: StaticString, line: UInt) {
        if !waitForNonExistence(timeout: screenTimeout) {
            XCTFail("\(description) did not go within \(Int(screenTimeout)) s", file: file, line: line)
        }
    }

    func waitUntilValue(_ description: String, is expected: String, file: StaticString, line: UInt) {
        if !wait(for: \.stringValue, toEqual: expected, timeout: screenTimeout) {
            let shown = exists ? stringValue ?? "no text" : "no element"
            XCTFail("\(description) is \"\(shown)\", not \"\(expected)\", after \(Int(screenTimeout)) s", file: file, line: line)
        }
    }

    /// The accessibility value as text; `value` itself is untyped.
    private var stringValue: String? { value as? String }
}
