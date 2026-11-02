@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// The running workout on the watch with the wrist lowered, the scene changing, and requests ending with a run shown.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchRemoteFeatureRunSceneTests {
    private typealias State = WatchRemoteFeature.State

    /// The reply to the request with ID `UUID(watch: id)`, carrying `state`.
    private static func answered(_ id: Int, _ state: PhoneState) -> WatchRemoteFeature.Action {
        .internal(.refreshAnswered(sentID: UUID(watch: id), reply(UUID(watch: id), state)))
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
        #expect(!retrying.state.refresh.isRetryScheduled)
        // From here the store is exhaustive: a `runRetryDue` that still fired would fail the test as unexpected.
        retrying.store.exhaustivity = .on
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
