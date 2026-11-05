@testable import AppFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain
import WorkoutTimerFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppWatchStartLifetimeTests {
    @Test(arguments: [false, true])
    func test_watchHealthAnswer_inactiveScene_resumesOnlyBeforeOriginalDeadline(expiresBeforeActive: Bool) async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.startGeneration = 1
        state.startIntent = AppFeature.StartIntent(generation: 1, origin: .watch(requestID: 7), workout: workout, stage: .health)
        state.startIntent?.acceptedAt = MonotonicInstant(now: clock)
        let store = makeStore(state) {
            $0.timerSession.end = { _ in }
            $0.continuousClock = clock
        }
        await store.send(.view(.scenePhaseChanged(.inactive))) { $0.hasScenePhase = true; $0.isSceneActive = false }

        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.startIntent?.stage = .awaitingActiveScene
        }
        #expect(store.state.destination == nil)
        await clock.advance(by: .seconds(expiresBeforeActive ? 30 : 29))
        await store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.startIntent = nil
            if expiresBeforeActive {
                $0.startGeneration = 2
            } else {
                $0.destination = .timer(timerState(for: workout, allowsWatchControl: true))
            }
        }
        if !expiresBeforeActive { await store.send(.destination(.dismiss)) { $0.destination = nil } }
        await store.finish()
    }
    @Test
    func test_watchHealthAnswer_atDeadlineWithoutTimeoutAction_updatesCacheButNeverPresents() async {
        let clock = TestClock<Duration>()
        let workout = makeWorkout(1)
        var state = loaded([workout])
        state.hasScenePhase = true
        state.startGeneration = 1
        state.isHealthRequestOutstanding = true
        state.startIntent = AppFeature.StartIntent(
            generation: 1,
            origin: .watch(requestID: 7),
            workout: workout,
            stage: .health,
            acceptedAt: MonotonicInstant(now: clock)
        )
        let store = makeStore(state) { $0.continuousClock = clock }
        await clock.advance(by: .seconds(30))

        await store.send(.internal(.healthPermissionAnswered(generation: 1, succeeded: true))) {
            $0.healthAccess = .determined
            $0.isHealthRequestOutstanding = false
            $0.startIntent = nil
            $0.startGeneration = 2
        }
        #expect(store.state.destination == nil)
        await store.finish()
    }
}
