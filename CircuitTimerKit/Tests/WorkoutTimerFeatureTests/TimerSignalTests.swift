@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@MainActor
struct TimerSignalTests {
    @Test
    func test_scenePhaseChanged_initialActive_beepsThreeOnce() async {
        let timer = TimerHarness(.fresh(), signals: true)
        let bursts = LockIsolated<[CueBurst]>([])
        timer.store.dependencies.cues.play = { burst in
            bursts.withValue { $0.append(burst) }
            return CueResult(outputs: .tone)
        }
        let baseline = SignalMoment(timer.store.state)
        await timer.store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.signals.last = baseline
            $0.signals.cueRevision = 1
            $0.haptic = HapticCue(kind: .countdown, revision: 1)
        }
        await timer.store.finish()
        #expect(bursts.value == [CueBurst(owner: timerID, revision: 1, tone: .countdown)])
        await timer.store.send(.view(.scenePhaseChanged(.active)))
        await timer.store.finish()
        #expect(bursts.value.count == 1)
    }

    @Test
    func test_scenePhaseChanged_inactive_stopsCueAndDropsBaseline() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.isSceneActive = true
        state.signals.last = SignalMoment(state)
        state.signals.cueRevision = 4
        state.signals.announcedStageIndex = 0
        state.haptic = HapticCue(kind: .stageStart, revision: 4)
        let timer = TimerHarness(state, signals: true)
        let suspends = LockIsolated<[Int]>([])
        timer.store.dependencies.cues.suspend = { _, revision in suspends.withValue { $0.append(revision) } }
        await timer.store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.isSceneActive = false
            $0.signals.last = nil
            $0.haptic = nil
        }
        await timer.store.finish()
        #expect(suspends.value == [4])
        let baseline = SignalMoment(timer.store.state)
        await timer.store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.signals.last = baseline
        }
        await timer.store.finish()
    }
    @Test
    func test_scenePhaseChanged_stageCrossedWhileInactive_doesNotAnnounceItOnReturn() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.isSceneActive = true
        state.signals.last = SignalMoment(state)
        state.signals.announcedStageIndex = 0
        let timer = TimerHarness(state, signals: true)
        await timer.store.send(.view(.scenePhaseChanged(.inactive))) {
            $0.isSceneActive = false
            $0.signals.last = nil
        }
        await timer.advance(seconds: 8)
        await timer.store.send(.view(.scenePhaseChanged(.active))) {
            $0.isSceneActive = true
            $0.settle(at: moment(8))
            $0.signals.last = SignalMoment($0)
            $0.signals.announcedStageIndex = 1
        }
        await timer.store.finish()
        #expect(timer.store.state.signals.cueRevision == 0)
    }

    @Test
    func test_cueFinished_staleRevision_doesNotReplaceCurrentFailures() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.isSceneActive = true
        state.signals.cueRevision = 2
        state.cueFailures = [.tone]
        let timer = TimerHarness(state)
        await timer.store.send(.internal(.cueFinished(revision: 1, CueResult(outputs: .tone))))
        await timer.store.send(.internal(.cueFinished(revision: 2, CueResult(outputs: .tone)))) {
            $0.cueFailures = []
        }
    }

    @Test
    func test_cueFinished_playedToneWithMissingVoice_clearsOnlyRecoveredFailures() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        state.isSceneActive = true
        state.signals.cueRevision = 2
        state.cueFailures = [.tone, .session]
        let timer = TimerHarness(state)
        await timer.store.send(.internal(.cueFinished(
            revision: 2,
            CueResult(outputs: .tone, failures: [.voiceUnavailable(language: "ru-RU")])
        ))) {
            $0.cueFailures = [.voice]
        }
    }

    @Test(arguments: [0, 1, 2])
    func test_task_newManualStage_eachSwitchDisablesOnlyItsOutput(disabled: Int) async {
        var state = WorkoutTimerFeature.State.fixture(.awaitingUser, schedule: Schedules.withPause)
        state.isSceneActive = true
        state.signals.last = SignalMoment(.fixture(.running, schedule: Schedules.withPause, elapsed: 0))
        state.signals.announcedStageIndex = 0
        state.$isSoundOn = SharedReader(value: disabled != 0)
        state.$isVibrationOn = SharedReader(value: disabled != 1)
        state.$isSpeechOn = SharedReader(value: disabled != 2)
        let timer = TimerHarness(state, signals: true)
        let bursts = LockIsolated<[CueBurst]>([])
        timer.store.dependencies.cues.play = { burst in
            bursts.withValue { $0.append(burst) }
            return CueResult()
        }
        await timer.store.send(.view(.task)) {
            $0.signals.last = SignalMoment($0)
            $0.signals.announcedStageIndex = 1
            $0.signals.cueRevision = 1
            if disabled != 1 { $0.haptic = HapticCue(kind: .stageStart, revision: 1) }
        }
        await timer.store.finish()
        let expected = CueBurst(
            owner: timerID,
            revision: 1,
            tone: disabled == 0 ? nil : .stageStart,
            announcement: disabled == 2 ? nil : .pause
        )
        #expect(bursts.value == [expected])
    }

    @Test
    func test_closeConfirmation_stayRestartingCountdown_signalsThreeImmediately() async {
        var state = WorkoutTimerFeature.State.fixture(.idle)
        state.isSceneActive = true
        state.recordSync = .stored(nil)
        state.destination = .closeConfirmation(.closeConfirmation(restart: .start))
        let timer = TimerHarness(state, signals: true)
        timer.store.dependencies.cues.play = { _ in CueResult(failures: [.playerFailed]) }
        await timer.store.send(.destination(.presented(.closeConfirmation(.stay(restart: .start))))) {
            $0.destination = nil
            $0.countdown = WorkoutTimerFeature.Countdown(.start)
            $0.clockGeneration = 2
            $0.requestedAwake = true
            $0.awakeRevision = 3
            $0.signals.last = SignalMoment($0)
            $0.signals.cueRevision = 1
            $0.haptic = HapticCue(kind: .countdown, revision: 1)
        }
        await timer.store.receive(.internal(.cueFinished(revision: 1, CueResult(failures: [.playerFailed])))) {
            $0.cueFailures = [.tone]
        }
        await timer.cancelClockLoop()
    }

}
