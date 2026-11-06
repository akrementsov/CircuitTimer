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

    /// A text of the page, such as a heading, found by its whole label; the page's text is not in a lazy container,
    /// so a block below the screen exists too.
    @discardableResult
    func assertText(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.staticTexts[text].waitUntilExists("The text \"\(text)\"", file: file, line: line)
        return self
    }

    /// A link of the page by its text, such as the contact address: a link, not plain text that only shows it.
    @discardableResult
    func assertLink(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.links[text].waitUntilExists("The link \"\(text)\"", file: file, line: line)
        return self
    }

    func tapBack(file: StaticString = #filePath, line: UInt = #line) -> AboutScreen {
        app.navigationBars.buttons["About"]
            .waitUntilHittable("Back to About", file: file, line: line)
            .tap()
        return AboutScreen(app, file: file, line: line)
    }
}
