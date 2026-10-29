@testable import WorkoutHealth

import Dependencies
import Foundation
import HealthKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkoutSessionsTests {
    private let health = FakeHealth()
    private let gate = TerminationGate()
    private let clock = TestClock<Duration>()
    private let sessions: WorkoutSessions
    private static let owner = UUID(fixture: 501)
    private static let other = UUID(fixture: 502)
    private static let now = moment(1_000)

    init() {
        sessions = WorkoutSessions(transport: health.transport, gate: gate) { Self.now }
    }

    private func start(_ owner: UUID = owner, at date: Date = moment(0)) async {
        await sessions.start(owner: owner, at: date, clock: clock)
    }

    private func end(_ owner: UUID = owner, at date: Date = moment(10)) async {
        await sessions.end(owner: owner, at: date, clock: clock)
    }

    private func endOrphans() async {
        await sessions.endOrphans(clock: clock)
    }

    /// Lets the session's watch task hand its events to the actor.
    private func settle() async {
        await Task.megaYield()
    }

    private func running(_ owner: UUID = owner, at date: Date = moment(0)) async -> FakeSession {
        await start(owner, at: date)
        let session = health.created.value.last!
        session.report(.changed(.running))
        await settle()
        return session
    }

    // MARK: - The main path

    @Test
    func test_start_canHoldSessions_observesThenStartsAtTheDate() async {
        await start(at: moment(3))

        #expect(health.created.value.count == 1)
        #expect(health.session(0).calls.value == [.observe, .start(moment(3))])
    }

    @Test
    func test_end_running_stopsEndsAndReleasesOnceEnded() async {
        let session = await running()

        await end(at: moment(10))
        #expect(session.calls.value == [.observe, .start(moment(0)), .stop(moment(10)), .end])

        session.report(.changed(.ended))
        await settle()
        #expect(session.calls.value.last == .release)
    }

    @Test
    func test_end_starting_endsWithoutStopUntilEnded() async {
        await start()
        let session = health.session(0)

        await end()
        #expect(session.calls.value == [.observe, .start(moment(0)), .end])

        session.report(.changed(.ended))
        await settle()
        #expect(session.calls.value == [.observe, .start(moment(0)), .end, .release])
    }

    @Test
    func test_endOrphans_foreignSession_endsAwaitsItsEndAndReleases() async {
        let orphan = FakeSession(activityID: UUID(fixture: 900))
        orphan.report(.changed(.ended))
        health.answerRecovery(.success(orphan))

        await endOrphans()
        await start()

        #expect(orphan.calls.value == [.observe, .end, .release])
        #expect(health.created.value.count == 1)
    }

    // MARK: - Tombstones and the gate

    @Test(arguments: [false, true])
    func test_start_endedOrLostOwner_createsNoSession(isLost: Bool) async {
        let session = await running()
        if isLost {
            session.report(.changed(.ended))
            await settle()
        } else {
            await end()
        }

        await start()

        #expect(health.created.value.count == 1)
    }

    @Test
    func test_end_twiceOrWithoutSlot_endsTheHandleOnceAndTombstones() async {
        let session = await running()

        await end(at: moment(10))
        await end(at: moment(11))
        await end(Self.other)
        await start(Self.other)

        #expect(session.calls.value == [.observe, .start(moment(0)), .stop(moment(10)), .end])
        #expect(health.created.value.count == 1)
    }

    @Test
    func test_end_wallClockBeforeTheStart_stopsAtTheStart() async {
        let session = await running(at: moment(10))

        await end(at: moment(5))

        #expect(session.calls.value == [.observe, .start(moment(10)), .stop(moment(10)), .end])
    }

    @Test
    func test_start_closedGate_createsNoSession() async {
        gate.close()

        await start()

        #expect(health.created.value.isEmpty)
    }

    @Test
    func test_start_gateClosedWhileWaitingForRecovery_createsNoSession() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()

        gate.close()
        health.answerRecovery(.success(nil))
        await recovering.value
        await starting.value

        #expect(health.created.value.isEmpty)
    }

    @Test
    func test_canHoldSessionsFalse_createsAndRecoversNothing() async {
        health.canHoldSessions.setValue(false)

        await start()
        await endOrphans()
        await end()
        await sessions.endAll(at: moment(20), clock: clock)

        #expect(health.created.value.isEmpty)
        #expect(health.recoveries.value == 0)
    }

    // MARK: - Recovery

    @Test
    func test_endOrphans_secondCallOrNothingRecovered_endsNothing() async {
        health.answerRecovery(.success(nil))

        await endOrphans()
        await endOrphans()
        await start()

        #expect(health.recoveries.value == 1)
        #expect(health.session(0).calls.value == [.observe, .start(moment(0))])
    }

    @Test
    func test_endOrphans_sessionWithAnOwnActivity_isNotEnded() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()
        // The start stops waiting and admits its session; recovery then returns the same session as another object.
        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await starting.value
        let recovered = FakeSession(activityID: health.session(0).activityID)

        health.answerRecovery(.success(recovered))
        await recovering.value

        #expect(recovered.calls.value.isEmpty)
        #expect(health.session(0).calls.value == [.observe, .start(moment(0))])
    }

    @Test
    func test_end_reservedStart_createsNoSessionAfterRecovery() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()

        await end()
        health.answerRecovery(.success(nil))
        await recovering.value
        await starting.value

        #expect(health.created.value.isEmpty)
    }

    @Test
    func test_start_createThrows_triesAgainOnTheNextStart() async {
        health.createFailures.setValue([FakeError()])

        await start()
        #expect(health.created.value.isEmpty)

        await start()
        #expect(health.created.value.count == 1)
    }

    @Test(arguments: [false, true])
    func test_endOrphans_recoveryThrows_waitingStartsAndRetriesGoOn(isCancellation: Bool) async {
        let recovering = Task { await endOrphans() }
        await settle()
        // The first start times out, admits a session that fails behind the earlier one, and waits for a retry.
        let first = Task { await start(at: moment(1)) }
        await settle()
        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await first.value
        health.session(0).report(.failed(HKError(.errorAnotherWorkoutSessionStarted)))
        await settle()
        let second = Task { await start(Self.other, at: moment(2)) }
        await settle()

        health.answerRecovery(.failure(isCancellation ? CancellationError() : FakeError()))
        await recovering.value
        await second.value

        #expect(Set(health.created.value.flatMap(\.calls.value).filter(\.isStart)) == [
            .start(moment(1)), .start(moment(2)), .start(Self.now),
        ])
        #expect(health.created.value.count == 3)
    }

    @Test
    func test_anotherSession_duringRecovery_retriesOnceAfterItAtNow() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start(at: moment(1)) }
        await settle()
        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await starting.value
        health.session(0).report(.failed(HKError(.errorAnotherWorkoutSessionStarted)))
        await settle()
        #expect(health.created.value.count == 1)

        health.answerRecovery(.success(nil))
        await recovering.value

        #expect(health.created.value.count == 2)
        #expect(health.session(1).calls.value == [.observe, .start(Self.now)])
    }

    @Test
    func test_anotherSession_afterTheOrphanEnded_retriesExactlyOnce() async {
        let orphan = FakeSession(activityID: UUID(fixture: 900))
        orphan.report(.changed(.ended))
        health.answerRecovery(.success(orphan))
        await endOrphans()

        await start()
        health.session(0).report(.failed(HKError(.errorAnotherWorkoutSessionStarted)))
        await settle()
        #expect(health.created.value.count == 2)
        #expect(health.session(1).calls.value == [.observe, .start(Self.now)])

        health.session(1).report(.failed(HKError(.errorAnotherWorkoutSessionStarted)))
        await settle()
        #expect(health.created.value.count == 2)
    }

    @Test
    func test_startFailure_otherCode_isNotRetried() async {
        let orphan = FakeSession(activityID: UUID(fixture: 900))
        orphan.report(.changed(.ended))
        health.answerRecovery(.success(orphan))
        await endOrphans()

        await start()
        health.session(0).report(.failed(FakeError()))
        await settle()

        #expect(health.created.value.count == 1)
    }

    @Test
    func test_endOrphans_orphanSilent_releasesItAfterTheTimeout() async {
        let orphan = FakeSession(activityID: UUID(fixture: 900))
        health.answerRecovery(.success(orphan))
        let recovering = Task { await endOrphans() }
        await settle()
        #expect(orphan.calls.value == [.observe, .end])

        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await recovering.value

        #expect(orphan.calls.value == [.observe, .end, .release])
    }

    // MARK: - HealthKit's events

    static let startingFailures: [SessionEvent] = [
        .failed(FakeError()),
        .failed(HKError(.errorBackgroundWorkoutSessionNotAllowed)),
        .changed(.ended),
    ]

    @Test(arguments: startingFailures)
    func test_startingSession_failsOrEnds_isReleasedAndMayStartAgain(event: SessionEvent) async {
        await start()
        let session = health.session(0)

        session.report(event)
        await settle()
        await start()

        let ended: [FakeSession.Call] = if case .failed = event { [.end, .release] } else { [.release] }
        #expect(session.calls.value == [.observe, .start(moment(0))] + ended)
        #expect(health.created.value.count == 2)
    }

    @Test(arguments: [SessionEvent.failed(FakeError()), .changed(.ended)])
    func test_runningSession_failsOrEnds_isLostAndNeverStartsAgain(event: SessionEvent) async {
        let session = await running()

        session.report(event)
        await settle()
        await start()

        let ended: [FakeSession.Call] = if case .failed = event { [.end, .release] } else { [.release] }
        #expect(session.calls.value == [.observe, .start(moment(0))] + ended)
        #expect(health.created.value.count == 1)
    }

    @Test
    func test_endingSession_fails_isReleasedAndWakesEndAll() async {
        await start()
        let session = health.session(0)
        let ending = Task { await sessions.endAll(at: moment(10), clock: clock) }
        await settle()

        session.report(.failed(FakeError()))
        await ending.value

        #expect(session.calls.value == [.observe, .start(moment(0)), .end, .release])
    }

    @Test(arguments: [HKWorkoutSessionState.stopped, .paused, .prepared])
    func test_startingSession_otherState_staysStarting(state: HKWorkoutSessionState) async {
        await start()
        let session = health.session(0)

        session.report(.changed(state))
        await settle()
        await end()

        #expect(session.calls.value == [.observe, .start(moment(0)), .end])
    }

    @Test
    func test_runningSession_repeatedRunningOrPaused_staysRunning() async {
        let session = await running()

        session.report(.changed(.running))
        session.report(.changed(.paused))
        await settle()
        await end(at: moment(10))

        #expect(session.calls.value == [.observe, .start(moment(0)), .stop(moment(10)), .end])
    }

    // MARK: - Concurrency

    @Test
    func test_start_concurrentForOneOwner_createsOneSession() async {
        async let first: Void = start()
        async let second: Void = start()
        _ = await (first, second)

        #expect(health.created.value.count == 1)
    }

    @Test
    func test_start_concurrentForOneOwnerDuringRecovery_createsOneSession() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let first = Task { await start() }
        let second = Task { await start() }
        await settle()

        health.answerRecovery(.success(nil))
        await recovering.value
        await first.value
        await second.value

        #expect(health.created.value.count == 1)
    }

    @Test
    func test_start_duringSlowRecovery_returnsAtTheTimeoutWithoutAwaitingIt() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()
        #expect(health.created.value.isEmpty)

        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await starting.value
        #expect(health.created.value.count == 1)

        health.answerRecovery(.success(nil))
        await recovering.value
    }

    @Test
    func test_start_cancelledWhileWaitingForRecovery_stopsWaitingAndRecoveryGoesOn() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()

        starting.cancel()
        await starting.value
        let orphan = FakeSession(activityID: UUID(fixture: 900))
        orphan.report(.changed(.ended))
        health.answerRecovery(.success(orphan))
        await recovering.value

        #expect(orphan.calls.value == [.observe, .end, .release])
    }

    @Test
    func test_start_waitAndRetryPaths_neverAdmitTwoSessions() async {
        let recovering = Task { await endOrphans() }
        await settle()
        let starting = Task { await start() }
        await settle()
        await clock.advance(by: WorkoutSessions.recoveryTimeout)
        await starting.value
        health.session(0).report(.failed(HKError(.errorAnotherWorkoutSessionStarted)))
        await settle()
        // The timer returns to the active scene and starts again, waiting for recovery like the first start.
        let again = Task { await start() }
        await settle()

        health.answerRecovery(.success(nil))
        await recovering.value
        await again.value

        #expect(health.created.value.count == 2)
        #expect(health.session(1).calls.value == [.observe, .start(moment(0))])
    }

    @Test
    func test_endAll_startingThatRunsLater_endsItAgainAndWaitsForTheLastEnd() async {
        await start(at: moment(0))
        let starting = health.session(0)
        let runningSession = await running(Self.other, at: moment(1))
        let isDone = LockIsolated(false)
        let ending = Task {
            await sessions.endAll(at: moment(10), clock: clock)
            isDone.setValue(true)
        }
        await settle()
        #expect(starting.calls.value == [.observe, .start(moment(0)), .end])
        #expect(runningSession.calls.value == [.observe, .start(moment(1)), .stop(moment(10)), .end])

        starting.report(.changed(.running))
        runningSession.report(.changed(.ended))
        await settle()
        #expect(starting.calls.value == [.observe, .start(moment(0)), .end, .stop(Self.now), .end])
        #expect(!isDone.value)

        starting.report(.changed(.ended))
        await ending.value
        #expect(starting.calls.value.last == .release)
    }

    @Test
    func test_endAll_cancelled_returnsAtOnceAndKeepsTheSessionHeld() async {
        await start()
        let session = health.session(0)
        let ending = Task { await sessions.endAll(at: moment(10), clock: clock) }
        await settle()

        ending.cancel()
        await ending.value
        #expect(session.calls.value == [.observe, .start(moment(0)), .end])

        session.report(.changed(.ended))
        await settle()
        #expect(session.calls.value.last == .release)
    }
}
