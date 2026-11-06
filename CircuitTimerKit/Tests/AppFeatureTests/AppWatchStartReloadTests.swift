@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutStorage
import WorkoutTimerFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartReloadTests {
    @Test(arguments: [false, true])
    func test_remoteReload_duringWatchHealth_cancelsOnlyAfterSelectedScheduleChanges(changesSchedule: Bool) async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var fetched = workout
        if changesSchedule { fetched.training[0].duration = .seconds(20) }
        let result = StoredWorkouts(workouts: [fetched])
        let gate = Gate()
        var state = loaded([workout])
        state.hasScenePhase = true
        state.runRestore = .resolved
        state.startGeneration = 1
        state.isHealthRequestOutstanding = true
        state.startIntent = .init(
            generation: 1,
            origin: .watch(requestID: 7),
            workout: workout,
            stage: .health,
            acceptedAt: MonotonicInstant(now: clock)
        )
        let store = makeStore(state, healthAccess: nil) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
            $0.workoutStorage.fetchAll = { await gate.wait(); return result }
        }

        await store.send(.internal(.workoutsChangedRemotely)) { $0.isReloading = true }
        gate.open()
        await store.receive(\.internal.workoutsLoaded) {
            $0.isReloading = false
            $0.workouts = .loaded(IdentifiedArray(uniqueElements: result.workouts))
            if changesSchedule {
                $0.startIntent = nil
                $0.startGeneration = 2
            }
        }
        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
            if !changesSchedule {
                $0.startIntent = nil
                $0.destination = .timer(timerState(for: workout, allowsWatchControl: true))
            }
        }
        if !changesSchedule { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
    }

    @Test
    func test_activeScene_opensWaitingStartAndRetriesStalledNotificationCleanup() async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.hasScenePhase = true
        state.isSceneActive = false
        state.isNotificationCleanupStalled = true
        state.startGeneration = 1
        state.startIntent = .init(
            generation: 1,
            origin: .watch(requestID: 7),
            workout: workout,
            stage: .awaitingActiveScene,
            acceptedAt: MonotonicInstant(now: clock)
        )
        let store = makeStore(state) {
            $0.continuousClock = clock
            $0.timerSession.end = { _ in }
        }

        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.startIntent = nil
            $0.destination = .timer(timerState(for: workout, allowsWatchControl: true))
        }
        await store.receive(.internal(.notificationCleanupFinished(true)), timeout: .seconds(1)) {
            $0.isNotificationCleanupStalled = false
        }
        await store.send(.destination(.dismiss)) { $0.destination = nil }
        await store.finish()
    }
}
