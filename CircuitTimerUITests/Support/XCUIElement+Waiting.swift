import XCTest

/// How long a screen waits for the app before it fails the test.
private let screenTimeout: TimeInterval = 10

/// Waits that fail the test at the line of the test, not of the screen: screens pass their caller's `file` and `line`.
/// Each checks its condition first: XCTest's waits poll once a second and check only after the first poll, so a
/// condition that already holds would still cost a second.
@MainActor
extension XCUIElement {
    @discardableResult
    func waitUntilExists(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        if !exists && !waitForExistence(timeout: screenTimeout) {
            XCTFail("\(description) did not appear within \(Int(screenTimeout)) s", file: file, line: line)
        }
        return self
    }

    @discardableResult
    func waitUntilHittable(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        // Hittability is read only once the element exists.
        if !(exists && isHittable) && !wait(for: \.isHittable, toEqual: true, timeout: screenTimeout) {
            XCTFail("\(description) could not be tapped within \(Int(screenTimeout)) s", file: file, line: line)
        }
        return self
    }

    func waitUntilGone(_ description: String, file: StaticString, line: UInt) {
        if exists && !waitForNonExistence(timeout: screenTimeout) {
            XCTFail("\(description) did not go within \(Int(screenTimeout)) s", file: file, line: line)
        }
    }

    /// Reading the value of an element that is not there yet fails the test, so it waits for the element first.
    func waitUntilValue(_ description: String, is expected: String, file: StaticString, line: UInt) {
        guard waitUntilExists(description, file: file, line: line).exists else { return }
        if stringValue != expected && !wait(for: \.stringValue, toEqual: expected, timeout: screenTimeout) {
            let shown = exists ? stringValue ?? "no text" : "no element"
            XCTFail("\(description) is \"\(shown)\", not \"\(expected)\", after \(Int(screenTimeout)) s", file: file, line: line)
        }
    }

    /// The accessibility value as text; `value` itself is untyped.
    private var stringValue: String? { value as? String }
}
