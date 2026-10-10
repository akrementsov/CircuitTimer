@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import WorkoutDomain

@MainActor
@Suite
struct TimerLoopTests {
    private typealias Action = WorkoutTimerFeature.Action

    private static func session(ended: LockIsolated<Bool>) -> TimerSessionClient {
        TimerSessionClient(requestAwake: { _, _, _ in }, end: { _ in }, isEnded: { _ in ended.value })
    }

    @Test(arguments: [
        (Duration.seconds(10), Duration.seconds(1)),
        (.milliseconds(9_400), .milliseconds(400)),
        (.milliseconds(1), .milliseconds(1)),
        (Duration(secondsComponent: 3, attosecondsComponent: 1), Duration(secondsComponent: 0, attosecondsComponent: 1)),
        (.zero, .seconds(1)),
    ])
    func test_wakeDelay_stageRemaining_isTheTimeToTheNextWholeSecond(remaining: Duration, delay: Duration) {
        #expect(WorkoutTimerFeature.wakeDelay(stageRemaining: remaining) == delay)
    }

    @Test
    func test_tickLoop_running_wakesWhenTheStageClockChangesItsSecond() async throws {
        let clock = TestClock<Duration>()
        let wall = LockIsolated(moment(0.4))
        let sent = LockIsolated<[Action]>([])
        var run = WorkoutRun(schedule: Schedules.workRest)
        run.start(at: origin)
        let task = Task { [run] in
            try await WorkoutTimerFeature.tickLoop(
                clock: clock,
                date: DateGenerator { wall.value },
                session: Self.session(ended: LockIsolated(false)),
                owner: timerID,
                run: run,
                generation: 7,
                send: Send { action in sent.withValue { $0.append(action) } }
            )
        }

        await clock.advance(by: .milliseconds(599))
        #expect(sent.value.isEmpty)
        // The wall clock is read again after each wake, so the next wake follows it.
        wall.setValue(moment(1.3))
        await clock.advance(by: .milliseconds(1))
        #expect(sent.value == [.internal(.ticked(generation: 7, isFinal: false))])
        await clock.advance(by: .milliseconds(699))
        #expect(sent.value.count == 1)
        await clock.advance(by: .milliseconds(1))
        #expect(sent.value.count == 2)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func test_tickLoop_runStops_sendsOneFinalTickAndReturns() async throws {
        let clock = TestClock<Duration>()
        let wall = LockIsolated(origin)
        let sent = LockIsolated<[Action]>([])
        var run = WorkoutRun(schedule: Schedules.short)
        run.start(at: origin)
        let task = Task { [run] in
            try await WorkoutTimerFeature.tickLoop(
                clock: clock,
                date: DateGenerator { wall.value },
                session: Self.session(ended: LockIsolated(false)),
                owner: timerID,
                run: run,
                generation: 7,
                send: Send { action in sent.withValue { $0.append(action) } }
            )
        }

        wall.setValue(moment(1))
        await clock.advance(by: .seconds(1))
        wall.setValue(moment(2))
        await clock.advance(by: .seconds(1))
        try await task.value

        #expect(sent.value == [
            .internal(.ticked(generation: 7, isFinal: false)),
            .internal(.ticked(generation: 7, isFinal: false)),
            .internal(.ticked(generation: 7, isFinal: true)),
        ])
    }

    @Test
    func test_loops_sessionAlreadyEnded_returnBeforeSleeping() async throws {
        let clock = LateClock(lateness: .zero)
        let sent = LockIsolated<[Action]>([])
        let session = Self.session(ended: LockIsolated(true))
        var run = WorkoutRun(schedule: Schedules.workRest)
        run.start(at: origin)

        try await WorkoutTimerFeature.tickLoop(
            clock: clock,
            date: DateGenerator { origin },
            session: session,
            owner: timerID,
            run: run,
            generation: 1,
            send: Send { action in sent.withValue { $0.append(action) } }
        )
        try await WorkoutTimerFeature.countdownLoop(
            clock: clock,
            session: session,
            owner: timerID,
            remaining: 3,
            generation: 1,
            send: Send { action in sent.withValue { $0.append(action) } }
        )

        #expect(sent.value.isEmpty)
        #expect(clock.state.value.deadlines.isEmpty)
    }

    @Test
    func test_loops_sessionEndsBetweenWakes_stopAfterTheirNextCheck() async throws {
        let ended = LockIsolated(false)
        let sent = LockIsolated<[Action]>([])
        let send = Send<Action> { action in
            sent.withValue { $0.append(action) }
            ended.setValue(true)
        }
        var run = WorkoutRun(schedule: Schedules.workRest)
        run.start(at: origin)

        try await WorkoutTimerFeature.tickLoop(
            clock: LateClock(lateness: .zero),
            date: DateGenerator { origin },
            session: Self.session(ended: ended),
            owner: timerID,
            run: run,
            generation: 1,
            send: send
        )
        #expect(sent.value == [.internal(.ticked(generation: 1, isFinal: false))])

        ended.setValue(false)
        try await WorkoutTimerFeature.countdownLoop(
            clock: LateClock(lateness: .zero),
            session: Self.session(ended: ended),
            owner: timerID,
            remaining: 3,
            generation: 1,
            send: send
        )
        #expect(sent.value.last == .internal(.countdownTicked(generation: 1)))
        #expect(sent.value.count == 2)
    }

    @Test
    func test_countdownLoop_lateWakes_keepEveryDeadlineOnTheFirstReading() async throws {
        let clock = LateClock(lateness: .milliseconds(500))
        let sent = LockIsolated<[Action]>([])

        try await WorkoutTimerFeature.countdownLoop(
            clock: clock,
            session: Self.session(ended: LockIsolated(false)),
            owner: timerID,
            remaining: 3,
            generation: 4,
            send: Send { action in sent.withValue { $0.append(action) } }
        )

        #expect(clock.state.value.deadlines.map(\.offset) == [.seconds(1), .seconds(2), .seconds(3)])
        #expect(sent.value == Array(repeating: .internal(.countdownTicked(generation: 4)), count: 3))
    }
}
