@testable import WorkoutTimerFeature

import ComposableArchitecture
import Testing

@MainActor
struct TimerScreenPreferenceTests {
    @Test(arguments: [false, true])
    func test_task_keepScreenOnDisabled_startsClockWithoutAwakeVote(running: Bool) async {
        let state = running ? WorkoutTimerFeature.State.appearing() : .fresh()
        state.$isKeepScreenOn = SharedReader(value: false)
        let timer = TimerHarness(state)
        await timer.send(.view(.task), saving: true) {
            $0.clockGeneration = 1
            if running { $0.clockAnchor = timer.anchor(totalElapsed: .zero) }
        }
        #expect(timer.calls.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test(arguments: [false, true])
    func test_task_preferenceChanged_updatesAwakeVoteWithoutResettingClock(enabled: Bool) async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.$isKeepScreenOn = SharedReader(value: enabled)
        state.requestedAwake = !enabled
        let timer = TimerHarness(state)
        await timer.store.send(.view(.task)) {
            $0.requestedAwake = enabled
            $0.awakeRevision = 2
        }
        await timer.store.finish()
        #expect(timer.calls.value == [.awake(enabled, 2)])
        #expect(timer.store.state.clockGeneration == 1)
        #expect(timer.writes.value.isEmpty)
    }
}
