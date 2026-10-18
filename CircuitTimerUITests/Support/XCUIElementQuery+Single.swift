import XCTest

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
