import UITestContract
import XCTest

@MainActor
struct SettingsScreen: Screen {
    enum Preference: String, CaseIterable {
        case sound = "Sound"
        case vibration = "Vibration"
        case speech = "Speak stage names"
        case backgroundNotifications = "Background notifications"
        case keepScreenOn = "Keep screen on"
        case iCloudSync = "iCloud sync"

        var identifier: String {
            switch self {
                case .sound: AccessibilityID.Settings.sound
                case .vibration: AccessibilityID.Settings.vibration
                case .speech: AccessibilityID.Settings.speech
                case .backgroundNotifications: AccessibilityID.Settings.backgroundNotifications
                case .keepScreenOn: AccessibilityID.Settings.keepScreenOn
                case .iCloudSync: AccessibilityID.Settings.iCloudSync
            }
        }
    }

    let app: XCUIApplication

    init(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        self.app = app
        app.navigationBars["Settings"].waitUntilExists("The Settings screen", file: file, line: line)
    }

    func setPreference(_ preference: Preference, to isOn: Bool, file: StaticString = #filePath, line: UInt = #line) -> Self {
        let toggle = app.switches[preference.identifier]
            .waitUntilHittable("The \(preference.rawValue) switch", file: file, line: line)
        toggle.waitUntilValue("The \(preference.rawValue) switch before the tap", is: isOn ? "0" : "1", file: file, line: line)
        toggle.tap()
        toggle.waitUntilValue("The \(preference.rawValue) switch after the tap", is: isOn ? "1" : "0", file: file, line: line)
        return self
    }

    @discardableResult
    func assertAllPreferences(areOn isOn: Bool, file: StaticString = #filePath, line: UInt = #line) -> Self {
        for preference in Preference.allCases {
            app.switches[preference.identifier]
                .waitUntilValue("The \(preference.rawValue) switch", is: isOn ? "1" : "0", file: file, line: line)
        }
        return self
    }

    /// Without the full version the iCloud switch is one button that reads as off, whatever is stored.
    @discardableResult
    func assertICloudSyncLocked(file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.buttons.matching(identifier: AccessibilityID.Settings.iCloudSync)
            .assertSingle("The locked iCloud sync card", file: file, line: line)
            .waitUntilValue("The locked iCloud sync card", is: "Off", file: file, line: line)
        XCTAssertFalse(app.switches[AccessibilityID.Settings.iCloudSync].exists, "An iCloud sync switch", file: file, line: line)
        return self
    }

    func tapLockedICloudSync(file: StaticString = #filePath, line: UInt = #line) -> PurchaseScreen<Self> {
        app.buttons[AccessibilityID.Settings.iCloudSync]
            .waitUntilHittable("The locked iCloud sync card", file: file, line: line)
            .tap()
        return PurchaseScreen(app, file: file, line: line)
    }

    @discardableResult
    func assertFullVersionPurchased(file: StaticString = #filePath, line: UInt = #line) -> Self {
        app.descendants(matching: .any)[AccessibilityID.Settings.fullVersionPurchased]
            .waitUntilExists("The Full Version row", file: file, line: line)
        XCTAssertFalse(app.buttons[AccessibilityID.Settings.buyFullVersion].exists, "The Buy the App row", file: file, line: line)
        return self
    }

    func tapAbout(file: StaticString = #filePath, line: UInt = #line) -> AboutScreen {
        app.buttons[AccessibilityID.Settings.about]
            .waitUntilHittable("The About button", file: file, line: line)
            .tap()
        return AboutScreen(app, file: file, line: line)
    }

    func tapWorkouts(file: StaticString = #filePath, line: UInt = #line) -> WorkoutListScreen {
        app.tabBars.buttons["Workouts"]
            .waitUntilHittable("The Workouts tab", file: file, line: line)
            .tap()
        return WorkoutListScreen(app, file: file, line: line)
    }
}
