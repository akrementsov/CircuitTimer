import UITestContract
import XCTest

extension XCTestCase {
    /// Launches the app into a scenario: its own data, no live clients, English, no tips. The only place a test
    /// creates the app, so no test runs it on the device's data.
    @MainActor
    func launch(_ scenario: AppScenario) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment[ScenarioLaunch.scenarioKey] = scenario.rawValue
        app.launchEnvironment[ScenarioLaunch.dependencyContextKey] = ScenarioLaunch.dependencyContext
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            // A user default set from the arguments: the key and its value are two arguments.
            "-com.apple.TipKit.HideAllTips", "1",
        ]
        app.launch()
        return app
    }
}
