import BackgroundExecution
import BackgroundNotifications
import CloudSync
import Dependencies
import Foundation
import SettingsFeature
import Sharing
import UITestContract
import WorkoutActivity
import WorkoutEditorFeature
import WorkoutStorage
import WorkoutTimerFeature

#if DEBUG
extension AppScenario {
    /// The scenario a UI test asked for in the launch environment. An unknown name stops the app: a typo would
    /// otherwise launch it on live storage.
    public static func requested(in environment: [String: String]) -> AppScenario? {
        guard let name = environment[ScenarioLaunch.scenarioKey] else {
            return nil
        }
        guard let scenario = AppScenario(rawValue: name) else {
            fatalError("Unknown UI test scenario \"\(name)\"; known: \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scenario
    }

    /// Sets every dependency the app reaches, so a scenario touches neither the device's workouts, run record and
    /// preferences, nor notifications, Live Activities, audio, background time or the real clock.
    /// `make lint` fails when a client, key or storage strategy is added without a line here.
    public func prepare(_ dependencies: inout DependencyValues) {
        dependencies.workoutStorage = .scenario(workouts)
        dependencies.workoutRunRecord = .previewValue
        dependencies.backgroundNotifications = .previewValue
        dependencies.liveActivity = .previewValue
        dependencies.cues = .previewValue
        dependencies.timerSession = .previewValue
        dependencies.backgroundTask = .previewValue
        dependencies.saveTip = .previewValue
        dependencies.appVersion = .init(shortVersion: { ScenarioFixture.appVersion })
        dependencies.cloudSync = .previewValue
        dependencies.defaultAppStorage = .inMemory
        dependencies.uuid = .incrementing
        // Never advanced: a started timer stands still on its first countdown digit.
        dependencies.continuousClock = TestClock()
        dependencies.date = .constant(Date(timeIntervalSinceReferenceDate: 800_000_000))
    }
}
#endif
