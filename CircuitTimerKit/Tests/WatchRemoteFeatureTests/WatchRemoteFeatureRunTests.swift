@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// The running workout on the watch: its digits count only under a lease from a reply of the run's own timer, at most
/// 10 s after the request was sent, renewed every 5 s; every reason to ask goes through one request at a time.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchRemoteFeatureRunTests {
    private typealias State = WatchRemoteFeature.State
    private typealias Lease = WatchRemoteFeature.Lease

    private static let start = MonotonicInstant(now: TestClock<Duration>())

    /// The reply to the request with ID `UUID(watch: id)`, carrying `state`.
    private static func answered(_ id: Int, _ state: PhoneState) -> WatchRemoteFeature.Action {
        .internal(.refreshAnswered(sentID: UUID(watch: id), reply(UUID(watch: id), state)))
    }

    // MARK: The lease

    @Test
    func test_reply_confirmingTheRun_opensTheLeaseFromTheRequestsSend() async {
        let harness = RunHarness()

        await harness.confirm(runningRun(), afterSeconds: 3)

        #expect(harness.state.lease == Lease(
            serial: 1, sentAt: Self.start, openedAt: earlier.addingTimeInterval(3), deadline: earlier.addingTimeInterval(10)
        ))
        let screen = harness.screen()
        #expect(screen?.digitsFrom == earlier.addingTimeInterval(3))
        #expect(screen?.digitsUntil == earlier.addingTimeInterval(10))
        #expect(screen?.note == nil)
        await harness.finish()
    }

    @Test(arguments: [(9_999, true), (10_000, false)])
    func test_reply_confirmsOnlyWithinTheLeaseOfItsRequest(milliseconds: Int, opens: Bool) async {
        let run = runningRun()
        let harness = RunHarness(.showing(run, inFlight: true))
        await harness.clock.advance(by: .milliseconds(milliseconds))

        await harness.store.send(Self.answered(9, runState(sequence: 3, run: run)))

        #expect((harness.state.lease != nil) == opens)
        await harness.finish()
    }

    @Test
    func test_lease_renewsFiveSecondsAfterTheSend() async {
        let harness = RunHarness()
        await harness.confirm(runningRun())

        await harness.advance(seconds: 4.9)
        #expect(harness.requests == 1)
        await harness.advance(seconds: 0.1)
        await harness.store.receive(\.internal.renewalDue)

        #expect(harness.requests == 2)
        await harness.finish()
    }

    /// Every action starts by dropping a lease the monotonic clock says ran out, even before its `leaseExpired`.
    @Test
    func test_anyAction_leaseRanOut_dropsItFirst() async {
        let harness = RunHarness(.showing(runningRun(), lease: true))
        await harness.clock.advance(by: .seconds(10))

        await harness.store.send(.view(.systemClockChanged))

        #expect(harness.state.lease == nil)
        #expect(harness.screen()?.digitsUntil == nil)
        #expect(harness.screen()?.note == .waiting)
    }

    @Test(arguments: [-3_600.0, 3_600.0])
    func test_systemClockChanged_movesTheLeasesWallEndToTheMonotonicRemainder(shift: Double) async throws {
        let harness = RunHarness(.showing(runningRun(endsIn: 7_200), lease: true))
        await harness.advance(seconds: 2)
        harness.wall.withValue { $0 = $0.addingTimeInterval(shift) }

        await harness.store.send(.view(.systemClockChanged))

        let now = harness.now
        let lease = try #require(harness.state.lease)
        #expect(lease.deadline == now.addingTimeInterval(8))
        #expect(lease.openedAt <= now)
        let screen = try #require(harness.screen())
        #expect(try #require(screen.digitsFrom) <= now)
        #expect(screen.digitsUntil == lease.deadline)
        #expect(screen.showsDigits(at: lease.deadline.addingTimeInterval(-0.001)))
        #expect(!screen.showsDigits(at: lease.deadline))
    }

    @Test(arguments: [(0, true), (1, false), (2, false)])
    func test_newerContent_sameLiveOwnerKeepsTheLease_anotherOwnerOrNotLiveDropsIt(variant: Int, keeps: Bool) async {
        let harness = RunHarness(.showing(runningRun(stage: "A"), lease: true))
        let next = switch variant {
            case 0: runState(sequence: 3, run: runningRun(stage: "B"))
            case 1: runState(sequence: 3, run: runningRun(owner: 2))
            default: runState(sequence: 3, run: runningRun(stage: "B"), live: false)
        }

        await harness.store.send(.internal(.event(.context(next))))

        #expect((harness.state.lease?.serial == 1) == keeps)
        await harness.finish()
    }

    @Test
    func test_stateWithoutARun_returnsToTheList() async {
        let harness = RunHarness(.showing(runningRun(), lease: true))

        await harness.store.send(.internal(.event(.context(runState(sequence: 3, run: nil)))))

        #expect(harness.state.run == nil)
        #expect(harness.state.lease == nil)
        #expect(harness.state.screen == .list(watchCatalog("Morning"), dimmed: nil, status: nil))
    }

    @Test
    func test_leaseExpired_ownOrAlreadyDroppedAsksOnce_anotherSerialChangesNothing() async {
        let own = RunHarness(.showing(runningRun(), lease: true))
        await own.store.send(.internal(.leaseExpired(serial: 1)))
        #expect(own.state.lease == nil)
        #expect(own.requests == 2)
        await own.finish()

        let dropped = RunHarness(.showing(runningRun()))
        await dropped.store.send(.internal(.leaseExpired(serial: 1)))
        #expect(dropped.requests == 1)
        await dropped.finish()

        let newer = RunHarness(.showing(runningRun(), lease: true))
        await newer.store.send(.internal(.leaseExpired(serial: 0)))
        #expect(newer.state.lease?.serial == 1)
        #expect(newer.requests == 1)
    }

    @Test
    func test_statusOutOfReach_dropsTheLease_andBackInReachResetsTheFailuresAndAsks() async {
        var state = State.showing(runningRun(), lease: true)
        state.refresh.failures = 2
        let harness = RunHarness(state)

        await harness.store.send(.internal(.event(.status(unreachable))))

        #expect(harness.state.lease == nil)
        #expect(harness.screen()?.note == .unreachable)

        await harness.store.send(.internal(.event(.status(reachable))))
        #expect(harness.state.refresh.failures == 0)
        #expect(harness.requests == 2)
        await harness.finish()
    }

    // MARK: The screen

    @Test
    func test_runScreen_digitsAndNotes_followThePhaseTheLeaseAndTheLink() {
        func screen(_ run: WatchRun, lease: Bool = true, change: (inout State) -> Void = { _ in }) -> State.RunScreen? {
            var state = State.showing(run, lease: lease)
            change(&state)
            guard case let .run(screen) = state.screen else { return nil }
            return screen
        }
        let deadline = earlier.addingTimeInterval(10)

        // Under the lease: the lease's end, or the stage's end if it comes first; the timeline starts at the opening.
        #expect(screen(runningRun(endsIn: 30))?.digitsUntil == deadline)
        #expect(screen(runningRun(endsIn: 30))?.digitsFrom == earlier)
        #expect(screen(runningRun(endsIn: 4))?.digitsUntil == earlier.addingTimeInterval(4))
        #expect(screen(heldRun(.paused(heldStage)))?.digitsUntil == deadline)
        for phase: WorkoutActivityAttributes.Phase in [.getReady(first: heldStage), .awaitingUser(next: heldStage), .finished] {
            #expect(screen(heldRun(phase))?.digitsUntil == nil)
            #expect(screen(heldRun(phase))?.note == nil)
        }
        // A stage that ended with no newer content shows no digits until the iPhone confirms the next one.
        #expect(screen(runningRun()) { $0.run?.isStageOver = true }?.digitsUntil == nil)
        #expect(screen(runningRun()) { $0.run?.isStageOver = true }?.note == .waiting)
        // Without a lease, the note says why.
        #expect(screen(runningRun(), lease: false)?.note == .waiting)
        #expect(screen(runningRun(), lease: false) { $0.link = unreachable }?.note == .unreachable)
        #expect(screen(runningRun(), lease: false) { $0.problem = .unreachable }?.note == .unreachable)
        #expect(screen(runningRun(), lease: false) {
            $0.link = LinkStatus(isActivated: true, isReachable: false, needsUnlock: true)
        }?.note == .unlock)
        // A lowered wrist shows neither digits nor a note.
        #expect(screen(runningRun()) { $0.isLuminanceReduced = true }?.digitsUntil == nil)
        #expect(screen(runningRun()) { $0.isLuminanceReduced = true }?.note == nil)
        // The digits go at the boundary itself.
        let shown = screen(runningRun())
        #expect(shown?.showsDigits(at: deadline.addingTimeInterval(-0.001)) == true)
        #expect(shown?.showsDigits(at: deadline) == false)
        #expect(screen(runningRun(), lease: false)?.showsDigits(at: earlier) == false)
    }

    @Test
    func test_runTooLarge_showsItsNotice_belowAnUpdateAndUntilAStateWithoutIt() async {
        let harness = RunHarness(.showing(runningRun()))

        await harness.store.send(.internal(.event(.context(runState(sequence: 3, run: nil, tooLarge: true)))))
        #expect(harness.state.screen == .notice(.runTooLarge))
        await harness.store.send(.internal(.event(.undecodable(peerSchemaVersion: 2))))
        #expect(harness.state.screen == .update(.watch))
        await harness.store.send(.internal(.event(.context(runState(sequence: 4, run: nil)))))

        #expect(!harness.state.isRunTooLarge)
        #expect(harness.state.screen == .list(watchCatalog("Morning"), dimmed: nil, status: nil))
    }

    @Test
    func test_needsRenewal_onlyForAShownRunThatCanChange_inFrontInReachAndRaised() {
        let feature = WatchRemoteFeature()
        let base = State.showing(runningRun())
        func needs(_ change: (inout State) -> Void) -> Bool {
            var state = base
            change(&state)
            return feature.needsRenewal(state)
        }

        #expect(needs { _ in })
        #expect(!needs { $0.run = nil })
        #expect(!needs { $0.run = WatchRemoteFeature.ShownRun(run: heldRun(.finished), isLive: true) })
        #expect(!needs { $0.isRunTooLarge = true })
        #expect(!needs { $0.problem = .incompatible(.phone) })
        #expect(!needs { $0.isSceneActive = false })
        #expect(!needs { $0.isLuminanceReduced = true })
        #expect(!needs { $0.link = unreachable })
    }

    // MARK: Reasons to ask

    @Test
    func test_acceptedState_withoutALiveLease_asksOnce() async {
        let unconfirmed = RunHarness(.showing(runningRun(stage: "A")))
        await unconfirmed.store.send(.internal(.event(.context(runState(sequence: 3, run: runningRun(stage: "B"))))))
        await unconfirmed.store.send(.internal(.event(.message(runState(sequence: 4, run: runningRun(stage: "C"))))))
        #expect(unconfirmed.requests == 1)
        await unconfirmed.finish()

        let notAccepted = RunHarness(.showing(runningRun(stage: "A")))
        await notAccepted.store.send(.internal(.event(.context(runState(sequence: 2, run: runningRun(stage: "A"))))))
        #expect(notAccepted.requests == 0)

        let underLease = RunHarness(.showing(runningRun(stage: "A"), lease: true))
        await underLease.store.send(.internal(.event(.context(runState(sequence: 3, run: runningRun(stage: "B"))))))
        #expect(underLease.requests == 1)
        await underLease.finish()
    }

    @Test
    func test_sameRunAgain_keepsItsStageEnd() async {
        let run = runningRun()
        let harness = RunHarness(.showing(run, lease: true))

        await harness.store.send(.internal(.event(.context(runState(sequence: 3, run: run)))))

        #expect(harness.state.runGeneration == 1)
        #expect(harness.state.run == WatchRemoteFeature.ShownRun(run: run, isLive: true))

        await harness.store.send(.internal(.event(.context(runState(sequence: 4, run: run, live: false)))))
        #expect(harness.state.runGeneration == 1)
        #expect(harness.state.run == WatchRemoteFeature.ShownRun(run: run, isLive: false))
        await harness.finish()
    }

    @Test
    func test_stageEnd_pastEndsAtOnce_futureEndsOnTheClockAndAsks() async {
        let past = RunHarness()
        await past.store.send(.internal(.event(.context(runState(sequence: 2, run: runningRun(endsIn: -1))))))
        #expect(past.state.run?.isStageOver == true)
        await past.finish()

        let future = RunHarness()
        await future.confirm(runningRun(endsIn: 3))
        #expect(future.state.run?.isStageOver == false)
        await future.advance(seconds: 3)
        await future.store.receive(\.internal.stageEnded)

        #expect(future.state.run?.isStageOver == true)
        #expect(future.screen()?.digitsUntil == nil)
        #expect(future.requests == 2)
        await future.finish()
    }

    @Test
    func test_stageEnded_olderGeneration_changesNothing() async {
        let harness = RunHarness(.showing(runningRun(stage: "A")))

        await harness.store.send(.internal(.stageEnded(generation: 0)))
        #expect(harness.state.run?.isStageOver == false)
        await harness.store.send(.internal(.event(.context(runState(sequence: 3, run: runningRun(stage: "B"))))))
        #expect(harness.state.runGeneration == 2)
        await harness.store.send(.internal(.stageEnded(generation: 1)))

        #expect(harness.state.run?.isStageOver == false)
        await harness.finish()
    }

    /// A confirmation of new content whose stage already ended asks at once; the same content waits for the renewal.
    @Test
    func test_confirmingReply_stageOver_newContentAsksAtOnce_sameContentWaits() async {
        let ended = runningRun(stage: "A", endsIn: -5)
        var sameState = State.showing(ended, inFlight: true)
        sameState.run?.isStageOver = true
        let same = RunHarness(sameState)
        await same.store.send(Self.answered(9, runState(sequence: 3, run: ended)))
        #expect(same.state.lease != nil)
        #expect(same.requests == 1)
        await same.finish()

        let new = RunHarness(.showing(runningRun(stage: "A"), inFlight: true))
        let next = runningRun(stage: "B", endsIn: -5)
        await new.store.send(Self.answered(9, runState(sequence: 3, run: next)))
        #expect(new.requests == 2)
        await new.finish()
    }

    /// A live reply a newer message of the same process overtook asks again at once, without counting a failure.
    @Test
    func test_overtakenLiveReply_otherContent_asksAgainWithoutAFailure() async {
        let harness = RunHarness(.showing(runningRun(stage: "B"), sequence: 3, inFlight: true))

        await harness.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), reply(UUID(watch: 9), runState(sequence: 2, run: runningRun(stage: "A")))
        )))

        #expect(harness.requests == 2)
        #expect(harness.state.refresh.failures == 0)
        #expect(harness.state.lease == nil)
        await harness.finish()
    }

    /// F11: a reply the order rejects confirms only the exact content shown under a live state of the same process.
    @Test(arguments: [(true, "A", true), (false, "A", false), (true, "B", false)])
    func test_overtakenLiveReply_opensTheLeaseOnlyForTheSameContentUnderALiveState(
        shownLive: Bool, answeredStage: String, opens: Bool
    ) async {
        let harness = RunHarness(.showing(runningRun(stage: "A"), sequence: 3, live: shownLive, inFlight: true))

        await harness.store.send(Self.answered(9, runState(sequence: 2, run: runningRun(stage: answeredStage))))

        #expect((harness.state.lease != nil) == opens)
        await harness.finish()
    }

    /// A reply that does not confirm the run schedules the run's own retry, which no new reason about the run hurries.
    @Test
    func test_notLiveReply_schedulesTheRunsRetry_whichAbsorbsNewReasons() async {
        let harness = RunHarness(.showing(runningRun(), inFlight: true))

        await harness.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), reply(UUID(watch: 9), runState(sequence: 3, run: runningRun(), live: false))
        )))
        #expect(harness.state.refresh.failures == 1)
        #expect(harness.state.refresh.isRetryScheduled)
        await harness.store.send(.internal(.stageEnded(generation: harness.state.runGeneration)))
        #expect(harness.requests == 1)

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.runRetryDue)

        #expect(harness.requests == 2)
        await harness.finish()
    }

    /// A reason about the list does not wait for the run's retry: it asks at once, and the old retry does nothing.
    @Test
    func test_listReason_duringTheRunsRetry_asksAtOnceAndTheRetryIsVoid() async {
        let harness = RunHarness(.showing(runningRun(), inFlight: true))
        await harness.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), reply(UUID(watch: 9), runState(sequence: 3, run: runningRun(), live: false))
        )))
        let retryGeneration = harness.state.refresh.runRetryGeneration

        await harness.store.send(.internal(.event(.context(runState(sequence: 4, run: runningRun(), live: false, digest: "B")))))
        #expect(harness.requests == 2)
        #expect(!harness.state.refresh.isRetryScheduled)
        await harness.store.send(.internal(.runRetryDue(generation: retryGeneration)))

        #expect(harness.requests == 2)
        await harness.finish()
    }

    /// An iPhone that keeps answering «not live» is asked after 5, 10, then 20 s; a confirmation resets the count.
    @Test
    func test_notLiveReplies_backOff5_10_20_andAConfirmationResetsThem() async {
        let run = runningRun(endsIn: 600)
        let harness = RunHarness(.showing(run, inFlight: true))
        await harness.store.send(Self.answered(9, runState(sequence: 3, run: run, live: false)))
        var sequence = 4
        for (failures, delay) in [(1, 5.0), (2, 10.0), (3, 20.0)] {
            #expect(harness.state.refresh.failures == failures)
            let requests = harness.requests
            await harness.advance(seconds: delay - 0.1)
            #expect(harness.requests == requests)
            await harness.advance(seconds: 0.1)
            await harness.store.receive(\.internal.runRetryDue)
            #expect(harness.requests == requests + 1)
            let notLive = failures < 3
            await harness.replies.answer(runState(sequence: sequence, run: run, live: !notLive))
            await harness.store.receive(\.internal.refreshAnswered)
            sequence += 1
        }

        #expect(harness.state.refresh.failures == 0)
        #expect(harness.state.lease != nil)
        await harness.finish()
    }

    @Test
    func test_retryDelay_growsFromFiveToTwentySeconds() {
        #expect((1...5).map { WatchRemoteFeature.retryDelay(afterFailures: $0) } == [
            .seconds(5), .seconds(10), .seconds(20), .seconds(20), .seconds(20),
        ])
    }

    @Test
    func test_runRetryDue_olderGeneration_changesNothing() async {
        var state = State.showing(runningRun())
        state.refresh.isRetryScheduled = true
        state.refresh.runRetryGeneration = 2
        let harness = RunHarness(state)

        await harness.store.send(.internal(.runRetryDue(generation: 1)))

        #expect(harness.state.refresh.isRetryScheduled)
        #expect(harness.requests == 0)

        // Its own generation after the retry was dropped does nothing either.
        var dropped = State.showing(runningRun())
        dropped.refresh.runRetryGeneration = 2
        let unscheduled = RunHarness(dropped)
        await unscheduled.store.send(.internal(.runRetryDue(generation: 2)))
        #expect(unscheduled.requests == 0)
    }

    /// A failed request drops the run's renewal and waits for its retry; the lease shows its digits until its end.
    @Test
    func test_failureDuringARun_keepsTheLeaseToItsEnd_andNoRunReasonHurriesTheRetry() async throws {
        let harness = RunHarness(.showing(runningRun(), lease: true, inFlight: true))

        await harness.store.send(.internal(.refreshFailed(sentID: UUID(watch: 9), .unreachable)))
        #expect(harness.state.refresh.isRetryScheduled)
        #expect(!harness.state.refresh.isRenewalDue)
        #expect(harness.screen()?.digitsUntil == earlier.addingTimeInterval(10))
        await harness.store.send(.internal(.stageEnded(generation: harness.state.runGeneration)))

        #expect(harness.requests == 2)
        await harness.finish()
    }

    /// A renewal due while its request is in flight waits for the reply, which confirms and asks exactly once.
    @Test
    func test_renewalDue_whileItsRequestIsInFlight_theConfirmationAsksOnce() async {
        let run = runningRun()
        let harness = RunHarness(.showing(run, lease: true, inFlight: true))

        await harness.store.send(.internal(.renewalDue(serial: 2)))
        #expect(harness.state.refresh.isRenewalDue)
        await harness.store.send(.internal(.renewalDue(serial: 1)))
        await harness.clock.advance(by: .seconds(6))
        await harness.store.send(Self.answered(9, runState(sequence: 3, run: run)))

        #expect(harness.state.lease?.serial == 2)
        #expect(!harness.state.refresh.isRenewalDue)
        #expect(harness.requests == 3)
        await harness.finish()
    }

    // MARK: Always On

    @Test
    func test_wristLowered_hidesTheDigitsAndStopsTheRenewal() async {
        var due = State.showing(runningRun(), lease: true, inFlight: true)
        due.refresh.isRenewalDue = true
        let lowered = RunHarness(due)
        await lowered.store.send(.view(.luminanceChanged(isReduced: true)))
        #expect(!lowered.state.refresh.isRenewalDue)
        await lowered.finish()

        let harness = RunHarness()
        await harness.confirm(runningRun())

        await harness.store.send(.view(.luminanceChanged(isReduced: true)))
        #expect(harness.screen()?.digitsUntil == nil)
        #expect(harness.screen()?.note == nil)
        await harness.advance(seconds: 10)

        #expect(harness.requests == 1)
        await harness.finish()
    }

    @Test
    func test_wristRaised_underALiveLease_renewsOnItsSchedule() async {
        let harness = RunHarness()
        await harness.confirm(runningRun())
        await harness.advance(seconds: 1)
        await harness.store.send(.view(.luminanceChanged(isReduced: true)))
        await harness.advance(seconds: 1)

        await harness.store.send(.view(.luminanceChanged(isReduced: false)))
        #expect(harness.screen()?.digitsUntil != nil)
        await harness.advance(seconds: 2.9)
        #expect(harness.requests == 1)
        await harness.advance(seconds: 0.1)
        await harness.store.receive(\.internal.renewalDue)

        #expect(harness.requests == 2)
        await harness.finish()
    }

    @Test
    func test_wristRaised_renewalAlreadyDue_asksOnce() async {
        let harness = RunHarness()
        await harness.confirm(runningRun())
        await harness.store.send(.view(.luminanceChanged(isReduced: true)))
        await harness.advance(seconds: 6)

        await harness.store.send(.view(.luminanceChanged(isReduced: false)))

        #expect(harness.requests == 2)
        await harness.finish()
    }

    @Test
    func test_wristRaised_requestInFlightPastItsRenewal_letsItsReplyAsk() async {
        var state = State.showing(runningRun(), lease: true, inFlight: true)
        state.isLuminanceReduced = true
        let harness = RunHarness(state)
        await harness.clock.advance(by: .seconds(6))

        await harness.store.send(.view(.luminanceChanged(isReduced: false)))

        #expect(harness.state.refresh.isRenewalDue)
        #expect(harness.requests == 2)
    }

    @Test
    func test_wristRaised_stageOverNothingInFlight_asksOnce() async {
        var state = State.showing(runningRun(), lease: true)
        state.isLuminanceReduced = true
        state.run?.isStageOver = true
        let harness = RunHarness(state)

        await harness.store.send(.view(.luminanceChanged(isReduced: false)))

        #expect(harness.requests == 2)
        await harness.finish()
    }

    @Test
    func test_luminanceUp_withoutAnEarlierLowering_asksNothing() async {
        let harness = RunHarness(.showing(runningRun(), lease: true))

        await harness.store.send(.view(.luminanceChanged(isReduced: false)))

        #expect(harness.requests == 1)
    }

    // MARK: The scene

    @Test
    func test_background_dropsTheLeaseAndEveryTimer_andNothingFiresAfter() async {
        let harness = RunHarness()
        await harness.confirm(runningRun())

        await harness.store.send(.view(.scenePhaseChanged(.background)))
        #expect(harness.state.lease == nil)
        #expect(harness.state.refresh.inFlight == nil)
        #expect(!harness.state.refresh.isRetryScheduled)
        await harness.advance(seconds: 60)

        #expect(harness.requests == 1)
        #expect(harness.state.run?.isStageOver == false)

        // The run's retry scheduled before leaving is gone too.
        let retrying = RunHarness(.showing(runningRun(), inFlight: true))
        await retrying.store.send(Self.answered(9, runState(sequence: 3, run: runningRun(), live: false)))
        #expect(retrying.state.refresh.isRetryScheduled)
        await retrying.store.send(.view(.scenePhaseChanged(.background)))
        await retrying.advance(seconds: 60)
        #expect(retrying.requests == 1)
    }

    @Test
    func test_inactiveKeepsTheLease_activeAfterLeavingSchedulesTheStageEndAgainWithoutALease() async {
        let harness = RunHarness()
        await harness.confirm(runningRun())

        await harness.store.send(.view(.scenePhaseChanged(.inactive)))
        #expect(harness.state.lease != nil)
        await harness.store.send(.view(.scenePhaseChanged(.background)))
        let generation = harness.state.runGeneration
        await harness.store.send(.view(.scenePhaseChanged(.active)))
        await harness.store.receive(\.internal.statusRead)

        #expect(harness.state.runGeneration == generation + 1)
        #expect(harness.state.lease == nil)
        await harness.finish()
    }

    @Test
    func test_wristLoweredAndRaised_showingARunUnderALiveLease_keepsItAndAsksNothing() async {
        let harness = RunHarness(.showing(runningRun(), lease: true))

        await harness.store.send(.view(.scenePhaseChanged(.inactive)))
        await harness.store.send(.view(.scenePhaseChanged(.active)))
        await harness.store.receive(\.internal.event)

        #expect(harness.state.lease?.serial == 1)
        #expect(harness.requests == 1)
    }

    // MARK: Ends of a request with a run shown

    @Test(arguments: [0, 1])
    func test_unreadableOrWrongIDReply_showingARun_isIncompatibleWithoutALease(variant: Int) async {
        let harness = RunHarness(.showing(runningRun(), inFlight: true))
        let envelope = variant == 0
            ? WatchReplyEnvelope.unreadable
            : reply(UUID(watch: 99), runState(sequence: 3, run: runningRun()))

        await harness.store.send(.internal(.refreshAnswered(sentID: UUID(watch: 9), envelope)))

        #expect(harness.state.problem == .incompatible(.phone))
        #expect(!harness.state.refresh.isRenewalDue)
        #expect(harness.state.lease == nil)
        #expect(harness.requests == 1)
    }

    @Test
    func test_replyOfAFinishedRequest_showingARun_opensNoLease() async {
        let run = runningRun()
        let harness = RunHarness(.showing(run, inFlight: true))

        await harness.store.send(Self.answered(8, runState(sequence: 3, run: run)))

        #expect(harness.state.lease == nil)
        #expect(harness.state.refresh.inFlight?.id == UUID(watch: 9))
    }
}
