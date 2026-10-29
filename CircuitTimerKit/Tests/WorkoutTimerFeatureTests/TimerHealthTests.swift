@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutHealth

/// When the timer asks for its workout session. The rest of each action is pinned by the exhaustive timer tests, so
/// these follow only the session.
@MainActor
struct TimerHealthTests {
    private let starts = LockIsolated<[Date]>([])

    private func harness(_ state: WorkoutTimerFeature.State, isSceneActive: Bool = true) -> TimerHarness {
        var state = state
        state.isSceneActive = isSceneActive
        let timer = TimerHarness(state, activity: true)
        timer.store.exhaustivity = .off(showSkippedAssertions: false)
        timer.store.dependencies.workoutHealth.start = { [starts] owner, date in
            #expect(owner == timerID)
            starts.withValue { $0.append(date) }
        }
        return timer
    }

    private func send(_ action: WorkoutTimerFeature.Action, to timer: TimerHarness) async {
        await timer.store.send(action)
        await Task.megaYield()
    }

    @Test
    func test_task_activeSceneOnceTheClockStarted_startsTheSessionOnce() async {
        let timer = harness(.appearing())

        await send(.view(.task), to: timer)

        #expect(starts.value == [origin])
        await timer.cancelClockLoop()
    }

    @Test
    func test_task_inactiveScene_startsNoSession() async {
        let timer = harness(.appearing(), isSceneActive: false)

        await send(.view(.task), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_activeScene_beforeTheClockStarted_startsNoSession() async {
        let timer = harness(.fresh())

        await send(.view(.scenePhaseChanged(.active)), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_returnToTheActiveScene_startsAgainButTicksDoNot() async {
        let timer = harness(.appearing())
        await send(.view(.task), to: timer)

        await timer.advance(seconds: 1)
        await Task.megaYield()
        #expect(starts.value == [origin])

        await send(.view(.scenePhaseChanged(.background)), to: timer)
        await send(.view(.scenePhaseChanged(.active)), to: timer)
        // The harness moves the wall clock with the test clock.
        #expect(starts.value == [origin, moment(1)])
        await timer.cancelClockLoop()
    }

    @Test
    func test_closing_startsNoSessionOnAnActiveSceneBeforeTheCoverGoes() async {
        let timer = harness(.fixture(.finished))
        // Holds the close before its dismissal, as a slow teardown would.
        let teardown = AsyncStream<Void>.makeStream()
        timer.store.dependencies.timerSession.end = { _ in for await _ in teardown.stream {} }

        await send(.view(.closeButtonTapped), to: timer)
        await send(.view(.scenePhaseChanged(.active)), to: timer)

        #expect(starts.value.isEmpty)
        teardown.continuation.finish()
        await timer.store.finish()
    }

    @Test
    func test_closeConfirmationStay_startsNoSession() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.destination = .closeConfirmation(.closeConfirmation(restart: nil))
        let timer = harness(state)

        await send(.destination(.presented(.closeConfirmation(.stay(restart: nil)))), to: timer)

        #expect(starts.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_closeBeforeTheClockStarted_endsTheSessionHarmlessly() async {
        var state = WorkoutTimerFeature.State.fresh()
        state.recordSync = .stored(nil)
        state.destination = .closeConfirmation(.closeConfirmation(restart: .start))
        let timer = harness(state)
        let ends = LockIsolated<[UUID]>([])
        timer.store.dependencies.workoutHealth.end = { owner, _ in ends.withValue { $0.append(owner) } }

        await send(.destination(.presented(.closeConfirmation(.finish))), to: timer)
        await timer.store.finish()

        #expect(ends.value == [timerID])
        #expect(starts.value.isEmpty)
    }
}
