import UITestContract
import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    /// Each launch resets the scenario's in-memory preferences; this checks retention within one process.
    func test_emptyList_toggleSettings_keepsValuesWhenReturningToTab() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .tapSettings()
            .assertAllPreferences(areOn: true)
            .setPreference(.sound, to: false)
            .setPreference(.vibration, to: false)
            .setPreference(.speech, to: false)
            .setPreference(.backgroundNotifications, to: false)
            .setPreference(.keepScreenOn, to: false)
            .setPreference(.iCloudSync, to: false)
            .tapWorkouts()
            .assertIsEmpty()
            .tapSettings()
            .assertAllPreferences(areOn: false)
            .setPreference(.sound, to: true)
            .setPreference(.vibration, to: true)
            .setPreference(.speech, to: true)
            .setPreference(.backgroundNotifications, to: true)
            .setPreference(.keepScreenOn, to: true)
            .setPreference(.iCloudSync, to: true)
            .assertAllPreferences(areOn: true)
    }

    func test_emptyList_openLegalPages_returnsThroughAboutToSettings() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .tapSettings()
            .tapAbout()
            .assertVersion("App version: \(ScenarioFixture.appVersion)")
            .tapPrivacyPolicy()
            .assertTitle("Privacy policy")
            .tapBack()
            .tapUserAgreement()
            .assertTitle("User agreement")
            .tapBack()
            .tapBack()
            .assertAllPreferences(areOn: true)
    }
}
