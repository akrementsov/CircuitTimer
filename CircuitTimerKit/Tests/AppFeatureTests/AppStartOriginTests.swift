@testable import AppFeature
@testable import WorkoutEditorFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutTimerFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppStartOriginTests {
    @Test
    func test_watchHealthAnswer_onSettingsWithoutEditor_opensCurrentSavedWorkout() async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var renamed = workout
        renamed.name = "Renamed"
        var state = loaded([renamed])
        state.selectedTab = .settings
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, origin: .watch(requestID: 7), workout: workout, stage: .health)
        state.hasScenePhase = true
        state.startIntent?.acceptedAt = MonotonicInstant(now: clock)
        let store = makeStore(state) {
            $0.timerSession.end = { _ in }
            $0.continuousClock = clock
        }

        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.destination = .timer(timerState(for: renamed, allowsWatchControl: true))
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }

    @Test
    func test_localStart_duringWatchIntent_freesLocalButtonAndKeepsWatchIntent() async throws {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.path.append(.editor(WorkoutEditorFeature.State(viewing: workout)))
        let id = try #require(state.path.ids.last)
        state.path[id: id, case: \.editor]?.isStarting = true
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, origin: .watch(requestID: 7), workout: workout)
        state.hasScenePhase = true
        state.startIntent?.acceptedAt = MonotonicInstant(now: clock)
        let store = makeStore(state) { $0.continuousClock = clock }

        await store.send(.path(.element(id: id, action: .editor(.delegate(.startRequested(workout)))))) {
            $0.path[id: id, case: \.editor]?.isStarting = false
        }
        #expect(store.state.startIntent == state.startIntent)
        await store.finish()
    }

    @Test
    func test_watchHealthAnswer_changedSchedule_cancelsInsteadOfOpeningTimer() async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var state = loaded([Workout(id: workout.id, name: workout.name)])
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, origin: .watch(requestID: 7), workout: workout, stage: .health)
        state.hasScenePhase = true
        state.startIntent?.acceptedAt = MonotonicInstant(now: clock)
        let store = makeStore(state) { $0.continuousClock = clock }

        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }
}
