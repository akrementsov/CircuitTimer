import Foundation
import UITestContract
import XCTest

@MainActor
struct AboutScreen: Screen {
    let app: XCUIApplication

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        app.navigationBars["About"].waitUntilExists("The About screen", file: file, line: line)
    }

    @discardableResult
    func assertVersion(_ version: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.staticTexts.matching(identifier: AccessibilityID.About.version)
            .matching(NSPredicate(format: "label == %@", version))
            .firstMatch
            .waitUntilExists("The app version \"\(version)\"", file: file, line: line)
        return self
    }

    func tapPrivacyPolicy(file: StaticString = #filePath, line: UInt = #line) -> LegalDocumentScreen {
        app.buttons[AccessibilityID.About.privacyPolicy]
            .waitUntilHittable("The Privacy policy button", file: file, line: line)
            .tap()
        return LegalDocumentScreen(app, file: file, line: line)
    }

    func tapUserAgreement(file: StaticString = #filePath, line: UInt = #line) -> LegalDocumentScreen {
        app.buttons[AccessibilityID.About.userAgreement]
            .waitUntilHittable("The User agreement button", file: file, line: line)
            .tap()
        return LegalDocumentScreen(app, file: file, line: line)
    }

    func tapBack(file: StaticString = #filePath, line: UInt = #line) -> SettingsScreen {
        app.navigationBars.buttons["Settings"]
            .waitUntilHittable("Back to Settings", file: file, line: line)
            .tap()
        return SettingsScreen(app, file: file, line: line)
    }
}
