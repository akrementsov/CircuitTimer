@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct TimerPreparationTests {
    @Test(arguments: [false, true])
    func test_task_delayedPreparation_startsThreeFullSecondsAfterReadiness(prepareFails: Bool) async throws {
        var state = WorkoutTimerFeature.State.fresh()
        state.isSceneActive = true
        state.recordSync = .stored(nil)
        state.isPreparingCountdown = true
        let timer = TimerHarness(state, signals: true)
        let bursts = LockIsolated<[CueBurst]>([])
        timer.store.dependencies.cues.prepare = { _, _ in
            try await timer.clock.sleep(for: .milliseconds(300))
            return CueResult(failures: prepareFails ? [.playerFailed] : [])
        }
        timer.store.dependencies.cues.play = { burst in
            bursts.withValue { $0.append(burst) }
            return CueResult(outputs: .tone)
        }
        await timer.store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
            $0.signals.cueRevision = 1
        }
        #expect(bursts.value.isEmpty)
        await timer.clock.advance(by: .milliseconds(300))
        let prepared = CueResult(failures: prepareFails ? [.playerFailed] : [])
        await timer.store.receive(.internal(.countdownPrepared(generation: 1, prepared))) {
            $0.isPreparingCountdown = false
            $0.signals.last = SignalMoment($0)
            $0.signals.cueRevision = 2
            $0.haptic = HapticCue(kind: .countdown, revision: 2)
            if prepareFails { $0.cueFailures = [.tone] }
        }
        if prepareFails {
            await timer.store.receive(.internal(.cueFinished(revision: 2, CueResult(outputs: .tone)))) {
                $0.cueFailures = []
            }
        }
        await timer.clock.advance(by: .milliseconds(999))
        #expect(timer.store.state.countdown?.remaining == 3)
        await timer.clock.advance(by: .milliseconds(1))
        await timer.store.receive(.internal(.countdownTicked(generation: 1))) {
            $0.countdown?.remaining = 2
            $0.signals.last = SignalMoment($0)
            $0.signals.cueRevision = 3
            $0.haptic = HapticCue(kind: .countdown, revision: 3)
        }
        #expect(bursts.value.map(\.revision) == [2, 3])
        await timer.cancelClockLoop()
    }

    @Test
    func test_countdownPrepared_newPreparationPending_doesNotCompleteOldGeneration() async {
        var state = WorkoutTimerFeature.State.fixture(.startCountdown)
        state.isPreparingCountdown = true
        let timer = TimerHarness(state, signals: true)
        await timer.store.send(.internal(.countdownPrepared(generation: 0, CueResult(failures: [.playerFailed]))))
        #expect(timer.store.state.isPreparingCountdown)
        #expect(timer.store.state.cueFailures.isEmpty)
    }

    @Test
    func test_task_beforeInitialActive_preparesAfterActivationAndThenSignalsThree() async {
        var state = WorkoutTimerFeature.State.fresh()
        state.recordSync = .stored(nil)
        let timer = TimerHarness(state, signals: true)
        let preparations = LockIsolated<[Int]>([])
        timer.store.dependencies.cues.prepare = { _, revision in
            preparations.withValue { $0.append(revision) }
            return CueResult()
        }
        await timer.store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
        }
        #expect(preparations.value.isEmpty)
        await timer.store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.clockGeneration = 2
            $0.signals.cueRevision = 1
        }
        await timer.store.receive(.internal(.countdownPrepared(generation: 2, CueResult()))) {
            $0.isPreparingCountdown = false
            $0.signals.last = SignalMoment($0)
            $0.signals.cueRevision = 2
            $0.haptic = HapticCue(kind: .countdown, revision: 2)
        }
        #expect(preparations.value == [1])
        await timer.cancelClockLoop()
    }

    @Test
    func test_playPauseButtonTapped_duringPreparation_cancelsAndFencesTheWarmup() async {
        var state = WorkoutTimerFeature.State.fresh()
        state.isSceneActive = true
        state.recordSync = .stored(nil)
        let timer = TimerHarness(state, signals: true)
        let fences = LockIsolated<[Int]>([])
        timer.store.dependencies.cues.prepare = { _, _ in
            try await timer.clock.sleep(for: .seconds(10))
            return CueResult()
        }
        timer.store.dependencies.cues.suspend = { _, revision in fences.withValue { $0.append(revision) } }
        await timer.store.send(.view(.task)) {
            $0.clockGeneration = 1
            $0.requestedAwake = true
            $0.awakeRevision = 1
            $0.signals.cueRevision = 1
        }
        await timer.store.send(.view(.playPauseButtonTapped)) {
            $0.countdown = nil
            $0.isPreparingCountdown = false
            $0.clockGeneration = 2
            $0.requestedAwake = false
            $0.awakeRevision = 2
            $0.signals.last = SignalMoment($0)
        }
        await timer.store.finish()
        #expect(fences.value.last == 1)
    }
}
