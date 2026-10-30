@testable import WorkoutHealth

import Foundation
import Testing

struct WorkoutHealthTrackTests {
    /// A track that started running at `start`, stopping by itself at `stopsAt`.
    private func running(from start: Date = moment(0), stopsAt: Date = moment(100)) -> WorkoutHealthTrack {
        var track = WorkoutHealthTrack()
        track.follow(.running(stopsAt: stopsAt), at: start)
        return track
    }

    private func workout(_ start: Double, _ end: Double, pauses: [(Double, Double)] = []) -> HealthWorkout {
        HealthWorkout(
            start: moment(start),
            end: moment(end),
            pauses: pauses.map { DateInterval(start: moment($0.0), end: moment($0.1)) }
        )
    }

    @Test
    func test_workout_running_endsAtTheCloseBeforeTheStopAndAtTheStopAfterIt() {
        let track = running(stopsAt: moment(100))

        #expect(track.workout(closingAt: moment(40)) == workout(0, 40))
        #expect(track.workout(closingAt: moment(150)) == workout(0, 100))
    }

    @Test
    func test_follow_twoPauses_keepsBothInOrderAndEndsAtTheLastStop() {
        var track = running(stopsAt: moment(100))
        track.follow(.halted, at: moment(10))
        track.follow(.running(stopsAt: moment(110)), at: moment(20))
        track.follow(.halted, at: moment(30))
        track.follow(.running(stopsAt: moment(120)), at: moment(45))

        #expect(track.workout(closingAt: moment(200)) == workout(0, 120, pauses: [(10, 20), (30, 45)]))
    }

    @Test(arguments: [WorkoutHealthTrack.Phase.halted, .finished])
    func test_follow_stopBeforeOrAfterTheForecast_endsAtTheEarlierOfBoth(phase: WorkoutHealthTrack.Phase) {
        var early = running(stopsAt: moment(100))
        early.follow(phase, at: moment(40))
        var late = running(stopsAt: moment(100))
        late.follow(phase, at: moment(130))

        #expect(early.workout(closingAt: moment(200)) == workout(0, 40))
        #expect(late.workout(closingAt: moment(200)) == workout(0, 100))
    }

    @Test
    func test_follow_runningStoppedByItselfAndResumedBeforeATick_closesThePauseFromTheStop() {
        var track = running(stopsAt: moment(30))
        track.follow(.running(stopsAt: moment(80)), at: moment(50))

        #expect(track.workout(closingAt: moment(200)) == workout(0, 80, pauses: [(30, 50)]))
    }

    @Test
    func test_follow_runningResumedAtItsStop_addsNoEmptyPause() {
        var track = running(stopsAt: moment(30))
        track.follow(.running(stopsAt: moment(80)), at: moment(30))

        #expect(track.workout(closingAt: moment(200)) == workout(0, 80))
    }

    @Test
    func test_follow_newForecastWhileTheOldOneIsAhead_replacesItWithoutAPause() {
        var track = running(stopsAt: moment(100))
        track.follow(.running(stopsAt: moment(60)), at: moment(20))

        #expect(track.workout(closingAt: moment(40)) == workout(0, 40))
        #expect(track.workout(closingAt: moment(200)) == workout(0, 60))
    }

    @Test
    func test_workout_closedWhileHalted_endsAtThePauseStart() {
        var track = running()
        track.follow(.halted, at: moment(25))

        #expect(track.workout(closingAt: moment(90)) == workout(0, 25))
    }

    @Test
    func test_follow_haltedThenFinished_endsAtThePauseStart() {
        var track = running()
        track.follow(.halted, at: moment(25))
        track.follow(.finished, at: moment(90))

        #expect(track.workout(closingAt: moment(200)) == workout(0, 25))
    }

    @Test
    func test_workout_neverRanOrZeroLength_isNil() {
        #expect(WorkoutHealthTrack().workout(closingAt: moment(10)) == nil)
        #expect(running(from: moment(5)).workout(closingAt: moment(5)) == nil)
    }

    @Test
    func test_workout_oneMillisecond_isSaved() {
        let track = running(from: moment(0))

        #expect(track.workout(closingAt: moment(0.001)) == workout(0, 0.001))
    }

    @Test
    func test_follow_thatChangesNothing_isIgnored() {
        var sameForecast = running(stopsAt: moment(100))
        sameForecast.follow(.running(stopsAt: moment(100)), at: moment(20))
        #expect(sameForecast == running(stopsAt: moment(100)))

        var halted = running()
        halted.follow(.halted, at: moment(10))
        var haltedAgain = halted
        haltedAgain.follow(.halted, at: moment(20))
        #expect(haltedAgain == halted)

        var finished = running()
        finished.follow(.finished, at: moment(10))
        var afterwards = finished
        afterwards.follow(.running(stopsAt: moment(200)), at: moment(20))
        afterwards.follow(.halted, at: moment(30))
        #expect(afterwards == finished)

        var idle = WorkoutHealthTrack()
        idle.follow(.halted, at: moment(10))
        idle.follow(.finished, at: moment(20))
        #expect(idle == WorkoutHealthTrack())
    }

    @Test
    func test_workout_endingByBeforeTheEnd_cutsTheEndAndThePauses() {
        var track = running(stopsAt: moment(100))
        track.follow(.halted, at: moment(10))
        track.follow(.running(stopsAt: moment(110)), at: moment(20))
        track.follow(.halted, at: moment(40))
        track.follow(.running(stopsAt: moment(120)), at: moment(60))
        track.follow(.halted, at: moment(70))
        track.follow(.running(stopsAt: moment(130)), at: moment(80))

        let cut = track.workout(closingAt: moment(200), endingBy: moment(50))
        #expect(cut == workout(0, 50, pauses: [(10, 20), (40, 50)]))
    }

    @Test(arguments: [0.0, -5])
    func test_workout_endingByAtOrBeforeTheStart_isNil(limit: Double) {
        #expect(running().workout(closingAt: moment(50), endingBy: moment(limit)) == nil)
    }

    @Test
    func test_follow_clockWentBackUnseenDuringAPause_keepsTheRunningTimeAndDropsThePause() {
        var track = running(stopsAt: moment(100))
        track.follow(.halted, at: moment(10))
        track.follow(.running(stopsAt: moment(95)), at: moment(7))

        #expect(track.workout(closingAt: moment(12)) == workout(-3, 12))
    }

    @Test
    func test_workout_closedBeforeTheNewestDate_movesACopyBack() {
        var track = running(stopsAt: moment(100))
        track.follow(.halted, at: moment(10))

        #expect(track.workout(closingAt: moment(4)) == workout(-6, 4))
        #expect(track.workout(closingAt: moment(50)) == workout(0, 10))
    }

    @Test
    func test_rebase_movesEveryDateByTheJump() {
        var track = running(stopsAt: moment(100))
        track.follow(.halted, at: moment(10))
        track.follow(.running(stopsAt: moment(110)), at: moment(20))
        track.rebase(from: moment(50), to: moment(40))

        #expect(track.workout(closingAt: moment(45)) == workout(-10, 45, pauses: [(0, 10)]))
        #expect(track.workout(closingAt: moment(200)) == workout(-10, 100, pauses: [(0, 10)]))
    }

    @Test
    func test_rebase_idleOrZeroJump_changesNothing() {
        var idle = WorkoutHealthTrack()
        idle.rebase(from: moment(50), to: moment(40))
        #expect(idle == WorkoutHealthTrack())

        var track = running()
        track.rebase(from: moment(50), to: moment(50))
        #expect(track == running())
    }
}
