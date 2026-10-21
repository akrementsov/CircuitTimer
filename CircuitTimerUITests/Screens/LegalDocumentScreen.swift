import XCTest

@MainActor
struct LegalDocumentScreen: Screen {
    let app: XCUIApplication

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        app.navigationBars.buttons["About"].waitUntilHittable("Back to About", file: file, line: line)
    }

    @discardableResult
    func assertTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.navigationBars[title].waitUntilExists("The \(title) screen", file: file, line: line)
        return self
    }

    func tapBack(file: StaticString = #filePath, line: UInt = #line) -> AboutScreen {
        app.navigationBars.buttons["About"]
            .waitUntilHittable("Back to About", file: file, line: line)
            .tap()
        return AboutScreen(app, file: file, line: line)
    }
}
