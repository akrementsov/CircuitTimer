@testable import AppScenarios

import Dependencies
import Foundation
import Sharing
import Testing
import UITestContract
import WorkoutDomain

#if DEBUG
struct AppScenarioTests {
    @Test
    func test_requested_noScenarioKey_returnsNil() {
        let environment = [ScenarioLaunch.dependencyContextKey: ScenarioLaunch.dependencyContext]

        #expect(AppScenario.requested(in: environment) == nil)
    }

    @Test(arguments: AppScenario.allCases)
    func test_requested_knownName_returnsItsScenario(scenario: AppScenario) {
        let environment = [ScenarioLaunch.scenarioKey: scenario.rawValue]

        #expect(AppScenario.requested(in: environment) == scenario)
    }

    /// The UI shows a workout only as normalized, so a fixture that normalization changes is not what the test sees.
    @Test(arguments: AppScenario.allCases)
    func test_workouts_everyScenario_needNoNormalization(scenario: AppScenario) {
        for workout in scenario.workouts {
            #expect(WorkoutLimits.normalizedStages(workout.warmUp) == workout.warmUp)
            #expect(WorkoutLimits.normalizedStages(workout.training) == workout.training)
            #expect(WorkoutLimits.normalizedStages(workout.coolDown) == workout.coolDown)
            #expect(WorkoutLimits.normalizedTrainingRounds(workout.trainingRounds) == workout.trainingRounds)
            #expect(workout.name.count <= WorkoutLimits.maxNameLength)
        }
    }

    // The checks below run in the live context, where a dependency `prepare` leaves alone would reach the device.

    @Test(arguments: AppScenario.allCases)
    func test_prepare_liveContext_standsTimeStill(scenario: AppScenario) throws {
        try withScenario(scenario) {
            @Dependency(\.date) var date
            @Dependency(\.continuousClock) var continuousClock

            #expect(date.now == Date(timeIntervalSinceReferenceDate: 800_000_000))
            let clock = try #require(continuousClock as? TestClock<Duration>)
            #expect(clock.now == TestClock<Duration>.Instant())
        }
    }

    @Test(arguments: AppScenario.allCases)
    func test_prepare_liveContext_countsUUIDsFromZero(scenario: AppScenario) {
        withScenario(scenario) {
            @Dependency(\.uuid) var uuid

            #expect(uuid() == UUID(0))
            #expect(uuid() == UUID(1))
        }
    }

    @Test(arguments: AppScenario.allCases)
    func test_prepare_liveContext_keepsPreferencesOffStandardDefaults(scenario: AppScenario) {
        let key = "appScenarioTests" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { UserDefaults.standard.removeObject(forKey: key) }

        withScenario(scenario) {
            @Shared(.appStorage(key)) var isOn = false
            @Dependency(\.defaultAppStorage) var defaults
            $isOn.withLock { $0 = true }

            #expect(defaults.bool(forKey: key))
            #expect(UserDefaults.standard.object(forKey: key) == nil)
        }
    }

    private func withScenario<R>(_ scenario: AppScenario, operation: () throws -> R) rethrows -> R {
        try withDependencies {
            $0.context = .live
            scenario.prepare(&$0)
        } operation: {
            try operation()
        }
    }
}
#endif
