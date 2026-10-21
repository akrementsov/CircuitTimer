import UITestContract
import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    func test_settings_togglePreferences_keepsValuesWhenReturningToTab() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .tapSettings()
            .assertAllPreferences(areOn: true)
            .setPreference(.sound, to: false)
            .setPreference(.vibration, to: false)
            .setPreference(.speech, to: false)
            .setPreference(.backgroundNotifications, to: false)
            .setPreference(.keepScreenOn, to: false)
            .tapWorkouts()
            .assertIsEmpty()
            .tapSettings()
            .assertAllPreferences(areOn: false)
            .setPreference(.sound, to: true)
            .setPreference(.vibration, to: true)
            .setPreference(.speech, to: true)
            .setPreference(.backgroundNotifications, to: true)
            .setPreference(.keepScreenOn, to: true)
            .assertAllPreferences(areOn: true)
    }

    func test_settings_openLegalPages_returnsThroughAboutToSettings() {
        let app = launch(.emptyList)

        WorkoutListScreen(app)
            .tapSettings()
            .tapAbout()
            .assertVersion("App version: 0.1.0")
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
