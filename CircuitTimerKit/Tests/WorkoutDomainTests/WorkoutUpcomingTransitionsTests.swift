@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct WorkoutUpcomingTransitionsTests {
    @Test
    func test_upcoming_running_stopsAtManualPauseWithoutChangingRun() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)
        let original = run

        let upcoming = run.upcomingTransitions(at: moment(3), limit: 32)

        #expect(upcoming.events.map(\.date) == [moment(10), moment(15)])
        #expect(upcoming.events.map(\.epochMs) == [moment(10).millisecondsSince1970, moment(15).millisecondsSince1970])
        #expect(upcoming.events.map(\.kind) == [
            .stageStarted(run.schedule.stages[1]),
            .stageStarted(run.schedule.stages[2]),
        ])
        #expect(!upcoming.hasMore)
        #expect(run == original)
    }

    @Test
    func test_upcoming_limit_countsWithheldPauseAndFinish() {
        var run = makeRun(makePausedWorkout())
        run.start(at: origin)
        let limited = run.upcomingTransitions(at: moment(3), limit: 1)
        #expect(limited.events.map(\.date) == [moment(10)])
        #expect(limited.hasMore)

        run.tick(at: moment(15))
        #expect(run.upcomingTransitions(at: moment(30), limit: 32) == .init(events: [], hasMore: false))
        run.resume(at: moment(40))
        let final = run.upcomingTransitions(at: moment(42), limit: 32)
        #expect(final.events.map(\.date) == [moment(50)])
        #expect(final.events.map(\.kind) == [.finished])
        #expect(!final.hasMore)
        for limit in [-1, 0] {
            let empty = run.upcomingTransitions(at: moment(42), limit: limit)
            #expect(empty.events.isEmpty)
            #expect(empty.hasMore)
        }
    }

    @Test
    func test_upcoming_elapsedBoundaries_areNeverReplayed() {
        let workout = Workout(
            id: UUID(fixture: 990),
            warmUp: [makeStage(1, .milliseconds(500)), makeStage(2, .milliseconds(500))]
        )
        var run = makeRun(workout)
        #expect(run.upcomingTransitions(at: origin, limit: 32) == .init(events: [], hasMore: false))
        run.start(at: origin)
        let first = run.upcomingTransitions(at: moment(0.1), limit: 32)
        #expect(first.events.map(\.date) == [moment(0.5), moment(1)])
        #expect(first.events.map(\.epochMs) == [moment(0.5).millisecondsSince1970, moment(1).millisecondsSince1970])
        #expect(run.upcomingTransitions(at: moment(0.5), limit: 32).events.map(\.kind) == [.finished])
        #expect(run.upcomingTransitions(at: moment(1), limit: 32) == .init(events: [], hasMore: false))
        run.pause(at: moment(0.1))
        #expect(run.upcomingTransitions(at: moment(0.2), limit: 32) == .init(events: [], hasMore: false))
        run.resume(at: moment(1))
        run.tick(at: moment(2))
        #expect(run.phase == .finished)
        #expect(run.upcomingTransitions(at: moment(2), limit: 32) == .init(events: [], hasMore: false))
    }
}
