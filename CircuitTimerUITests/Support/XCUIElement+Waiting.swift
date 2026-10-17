import XCTest

/// How long a screen waits for the app before it fails the test.
private let timeout: TimeInterval = 10

/// Waits that fail the test at the line of the test, not of the screen: screens pass their caller's `file` and `line`.
@MainActor
extension XCUIElement {
    @discardableResult
    func waitUntilExists(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCTFail("\(description) did not appear within \(Int(timeout)) s", file: file, line: line)
        }
        return self
    }

    @discardableResult
    func waitUntilHittable(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        if !wait(for: NSPredicate(format: "exists == true AND hittable == true")) {
            XCTFail("\(description) could not be tapped within \(Int(timeout)) s", file: file, line: line)
        }
        return self
    }

    func waitUntilGone(_ description: String, file: StaticString, line: UInt) {
        if !waitForNonExistence(timeout: timeout) {
            XCTFail("\(description) did not go within \(Int(timeout)) s", file: file, line: line)
        }
    }

    func waitForValue(_ expected: String, of description: String, file: StaticString, line: UInt) {
        if !wait(for: NSPredicate(format: "value == %@", expected)) {
            let shown = exists ? String(describing: value ?? "nil") : "no element"
            XCTFail("\(description) is \"\(shown)\", not \"\(expected)\", after \(Int(timeout)) s", file: file, line: line)
        }
    }

    private func wait(for predicate: NSPredicate) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

@MainActor
extension XCUIElementQuery {
    /// The single element the query matches. User data has no identifier, so two matches would leave a test
    /// checking either of them.
    func assertSingle(_ description: String, file: StaticString, line: UInt) -> XCUIElement {
        firstMatch.waitUntilExists(description, file: file, line: line)
        let matches = count
        if matches != 1 {
            XCTFail("\(description) matches \(matches) elements, not one", file: file, line: line)
        }
        return firstMatch
    }
}
