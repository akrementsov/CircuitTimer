import UITestContract
import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    /// Each launch resets the scenario's in-memory preferences; this checks retention within one process.
    func test_emptyList_toggleSettings_keepsValuesWhenReturningToTab() {
        // Long, not stuck: after each of the twelve switch taps XCTest waits 1.3 s for the app to go idle, locally and on
        // CI alike. The test takes 35 s locally and 48–60 s on the CI runner, which ran out the default 60 s at its last
        // step.
        executionTimeAllowance = 120
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
