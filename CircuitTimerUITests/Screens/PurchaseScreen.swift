import UITestContract
import XCTest

/// The purchase sheet over `Source`, the screen it returns to once it closes.
@MainActor
struct PurchaseScreen<Source: Screen>: Screen {
    let app: XCUIApplication

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        app.buttons[AccessibilityID.Purchase.restore].waitUntilExists("The purchase sheet", file: file, line: line)
    }

    /// The plaque that says why a locked feature opened the sheet.
    func assertReason(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        let reason = app.descendants(matching: .any)[AccessibilityID.Purchase.reason]
            .waitUntilExists("The sheet's reason", file: file, line: line)
        XCTAssertEqual(reason.label, text, "The sheet's reason", file: file, line: line)
        return self
    }

    func tapBuy(file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.buttons[AccessibilityID.Purchase.buy]
            .waitUntilHittable("The Buy button", file: file, line: line)
            .tap()
        return self
    }

    func assertPurchased(file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.descendants(matching: .any)[AccessibilityID.Purchase.purchased]
            .waitUntilExists("The sheet's thanks", file: file, line: line)
        return self
    }

    func tapClose(file: StaticString = #filePath, line: UInt = #line) -> Source {
        leave(through: AccessibilityID.Purchase.close, "The Close button", file: file, line: line)
    }

    func tapDone(file: StaticString = #filePath, line: UInt = #line) -> Source {
        leave(through: AccessibilityID.Purchase.done, "The Done button", file: file, line: line)
    }

    private func leave(through identifier: String, _ description: String, file: StaticString, line: UInt) -> Source {
        let button = app.buttons[identifier].waitUntilHittable(description, file: file, line: line)
        button.tap()
        button.waitUntilGone("The purchase sheet", file: file, line: line)
        return Source(app, file: file, line: line)
    }
}
