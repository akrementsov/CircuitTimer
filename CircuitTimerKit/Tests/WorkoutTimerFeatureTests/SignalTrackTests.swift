@testable import WorkoutTimerFeature

import Testing
import WorkoutDomain

@MainActor
struct SignalTrackTests {
    @Test
    func test_update_freshCountdown_emitsOnce() {
        var track = SignalTrack()
        let moment = SignalMoment(.fresh())
        #expect(track.update(moment) == SignalEvent(tone: .countdown))
        #expect(track.update(moment) == nil)
    }

    @Test(arguments: [TimerPhase.running, .awaitingUser, .paused, .finished])
    func test_update_restoredPhase_doesNotReplay(_ phase: TimerPhase) {
        var track = SignalTrack()
        let schedule = phase == .awaitingUser ? Schedules.withPause : Schedules.workRest
        #expect(track.update(SignalMoment(.fixture(phase, schedule: schedule))) == nil)
    }

    @Test
    func test_update_stageStart_winsOverShortCountdown() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fresh(Schedules.short)))
        let state = WorkoutTimerFeature.State.fixture(.running, schedule: Schedules.short, elapsed: 0)
        #expect(track.update(SignalMoment(state)) == SignalEvent(tone: .stageStart, announcement: .named("Stage 1")))
    }

    @Test
    func test_update_skippedSeconds_emitsOnlyCurrentSecond() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fixture(.running, elapsed: 5)))
        #expect(track.update(SignalMoment(.fixture(.running, elapsed: 8))) == SignalEvent(tone: .countdown))
        #expect(track.update(SignalMoment(.fixture(.running, elapsed: 8))) == nil)
    }

    @Test
    func test_update_sameStageResume_omitsName() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fixture(.running)))
        _ = track.update(SignalMoment(.fixture(.paused)))
        #expect(track.update(SignalMoment(.fixture(.running))) == SignalEvent(tone: .stageStart))
    }

    @Test
    func test_update_restoredPausedResume_announcesName() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fixture(.paused)))
        #expect(track.update(SignalMoment(.fixture(.running))) == SignalEvent(tone: .stageStart, announcement: .named("Stage 1")))
    }

    @Test
    func test_update_manualPause_announcesPause() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fixture(.running, schedule: Schedules.withPause, elapsed: 0)))
        let paused = WorkoutTimerFeature.State.fixture(.awaitingUser, schedule: Schedules.withPause)
        #expect(track.update(SignalMoment(paused)) == SignalEvent(tone: .stageStart, announcement: .pause))
    }

    @Test
    func test_update_finish_emitsOnce() {
        var track = SignalTrack()
        _ = track.update(SignalMoment(.fixture(.running)))
        let finished = SignalMoment(.fixture(.finished))
        #expect(track.update(finished) == SignalEvent(tone: .finish))
        #expect(track.update(finished) == nil)
    }
}
