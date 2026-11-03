@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// Pause and Resume on the watch: the control exists only under a live lease while the stage runs, a command is a
/// request of its own, its reply carries the lease on or revokes it but never opens one, and its outcome shows only on
/// the run it is about.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchRemoteCommandTests {
    private typealias State = WatchRemoteFeature.State

    private static func controlReply(_ id: UUID, _ result: WatchControlResult, _ state: PhoneState) -> WatchReplyEnvelope {
        WatchReplyEnvelope(requestID: id, reply: .control(result, state))
    }

    /// A harness showing `run` under a live lease, with Pause or Resume ready to tap.
    private static func harness(_ run: WatchRun = runningRun()) -> RunHarness {
        RunHarness(.showing(run, lease: true))
    }

    /// Taps the control and returns the command's ID.
    private static func tap(_ harness: RunHarness) async throws -> UUID {
        await harness.store.send(.view(.controlButtonTapped))
        return try #require(harness.state.command?.id)
    }

    private static func control(_ harness: RunHarness) -> State.RunControl? {
        guard case let .button(control) = harness.screen()?.controlSlot else { return nil }
        return control
    }

    // MARK: The control

    @Test
    func test_tap_sendsTheShownCommandWithItsGenerationAndDigest_andClearsTheLastNote() async throws {
        let base = runningRun()
        let content = WorkoutActivityAttributes.ContentState(phase: base.content.phase, controlGeneration: 6)
        let run = WatchRun(owner: base.owner, attributes: base.attributes, content: content)
        var state = State.showing(run, lease: true)
        state.commandNote = .init(note: .failed, run: run)
        let harness = RunHarness(state)

        let id = try await Self.tap(harness)

        #expect(harness.state.command == .init(id: id, owner: run.owner, command: .pause))
        #expect(harness.state.commandNote == nil)
        await harness.replies.waiting.wait { !$0.isEmpty }
        #expect(harness.sent.value == [.control(owner: run.owner, command: .pause, generation: 6, knownCatalogDigest: "A")])
        await harness.finish()
    }

    enum Slot: CaseIterable, Sendable {
        case running
        case paused
        case noLease
        case stageOver
        case wristLowered
        case getReady
        case finished
    }

    @Test(arguments: Slot.allCases)
    func test_controlSlot_showsOnlyUnderALeaseWhileTheStageRuns(slot: Slot) {
        let run: WatchRun = switch slot {
            case .paused: heldRun(.paused(heldStage))
            case .getReady: heldRun(.getReady(first: heldStage))
            case .finished: heldRun(.finished)
            default: runningRun(endsIn: 30)
        }
        var state = State.showing(run, lease: slot != .noLease)
        if slot == .stageOver { state.run?.isStageOver = true }
        if slot == .wristLowered { state.isLuminanceReduced = true }

        guard case let .run(screen) = state.screen else {
            Issue.record("No run on screen")
            return
        }
        switch slot {
            case .running:
                // The lease ends before the stage.
                #expect(screen.controlSlot == .button(.init(command: .pause, isEnabled: true, until: earlier.addingTimeInterval(10))))
            case .paused:
                #expect(screen.controlSlot == .button(.init(command: .resume, isEnabled: true, until: earlier.addingTimeInterval(10))))
            case .noLease, .stageOver, .wristLowered:
                #expect(screen.controlSlot == .reserved)
            case .getReady, .finished:
                #expect(screen.controlSlot == State.ControlSlot.none)
        }
    }

    @Test
    func test_controlSlot_runningStageEndingFirst_endsTheControlAtTheStageEnd() {
        let state = State.showing(runningRun(endsIn: 4), lease: true)

        guard case let .run(screen) = state.screen, case let .button(control) = screen.controlSlot else {
            Issue.record("No control on screen")
            return
        }
        #expect(control.until == earlier.addingTimeInterval(4))
    }

    @Test
    func test_control_isDisabledWhileItsTimersCommandWaits_orTheSceneIsInactive_andTheDigitsKeepCounting() async throws {
        let harness = Self.harness()
        _ = try await Self.tap(harness)

        #expect(Self.control(harness)?.isEnabled == false)
        #expect(harness.screen()?.digitsUntil == earlier.addingTimeInterval(10))

        var otherOwner = State.showing(runningRun(owner: 2), lease: true)
        otherOwner.command = .init(id: UUID(watch: 1), owner: runningRun(owner: 1).owner, command: .pause)
        guard case let .run(screen) = otherOwner.screen, case let .button(control) = screen.controlSlot else {
            Issue.record("No control on screen")
            return
        }
        #expect(control.isEnabled)

        var inactive = State.showing(runningRun(), lease: true)
        inactive.isSceneActive = false
        guard case let .run(inactiveScreen) = inactive.screen, case let .button(inactiveControl) = inactiveScreen.controlSlot else {
            Issue.record("No control on screen")
            return
        }
        #expect(!inactiveControl.isEnabled)
        await harness.finish()
    }

    enum Untappable: CaseIterable, Sendable {
        case afterItsEnd
        case waiting
        case noLease
    }

    @Test(arguments: Untappable.allCases)
    func test_tap_whenTheControlCannotBeUsed_sendsNothing(untappable: Untappable) async {
        let endsIn: Double = untappable == .afterItsEnd ? 5 : 30
        let harness = RunHarness(.showing(runningRun(endsIn: endsIn), lease: untappable != .noLease))
        switch untappable {
            case .afterItsEnd:
                // The stage ended under a live lease, before its `stageEnded` arrived.
                harness.wall.withValue { $0 = earlier.addingTimeInterval(endsIn) }
            case .waiting:
                await harness.store.send(.view(.controlButtonTapped))
            case .noLease:
                break
        }
        let sentBefore = harness.state.command

        await harness.store.send(.view(.controlButtonTapped))

        #expect(harness.state.command == sentBefore)
        await harness.finish()
    }

    // MARK: Notes

    @Test
    func test_notes_theLinksReasonComesFirst_thenTheCommandsOutcome_onlyOnTheRunItIsAbout() {
        let run = runningRun()
        var state = State.showing(run)
        state.commandNote = .init(note: .checking, run: run)
        #expect(state.runScreenNote == .commandChecking)

        state.link = unreachable
        #expect(state.runScreenNote == .unreachable)

        state.link = LinkStatus(isActivated: true, isReachable: false, needsUnlock: true)
        #expect(state.runScreenNote == .unlock)

        var other = State.showing(run, lease: true)
        other.commandNote = .init(note: .changed, run: runningRun(stage: "Before"))
        #expect(other.runScreenNote == nil)

        var underLease = State.showing(run, lease: true)
        underLease.commandNote = .init(note: .failed, run: run)
        #expect(underLease.runScreenNote == .commandFailed)
    }

    /// A newer live content of the same timer hides «Checking…», the same content keeps it; the state may keep the note.
    @Test(arguments: [false, true])
    func test_checking_hiddenByNewContentOfTheSameTimer_keptForTheSameContent(isNewContent: Bool) async {
        let run = runningRun()
        var state = State.showing(run, lease: true)
        state.commandNote = .init(note: .checking, run: run)
        let harness = RunHarness(state)
        let next = isNewContent ? runningRun(stage: "Next") : run

        await harness.store.send(.internal(.event(.message(runState(sequence: 3, run: next)))))

        #expect((harness.screen()?.note == .commandChecking) == !isNewContent)
        await harness.finish()
    }

    @Test
    func test_checking_clearedByAConfirmingRefreshOfTheSameTimer_notByOneThatConfirmsNothing() async {
        let run = runningRun()
        var state = State.showing(run, inFlight: true)
        state.commandNote = .init(note: .checking, run: run)
        let notConfirming = RunHarness(state)
        await notConfirming.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), reply(UUID(watch: 9), runState(sequence: 3, run: run, live: false))
        )))
        #expect(notConfirming.state.commandNote?.note == .checking)
        await notConfirming.finish()

        let confirming = RunHarness(state)
        await confirming.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), reply(UUID(watch: 9), runState(sequence: 3, run: run))
        )))
        #expect(confirming.state.commandNote == nil)
        await confirming.finish()
    }

    @Test
    func test_note_goesWithAnotherTimer_orNoRun() async {
        let run = runningRun()
        var state = State.showing(run, lease: true)
        state.commandNote = .init(note: .failed, run: run)
        let anotherTimer = RunHarness(state)
        await anotherTimer.store.send(.internal(.event(.message(runState(sequence: 3, run: runningRun(owner: 2))))))
        #expect(anotherTimer.state.commandNote == nil)
        await anotherTimer.finish()

        let noRun = RunHarness(state)
        await noRun.store.send(.internal(.event(.message(runState(sequence: 3, run: nil)))))
        #expect(noRun.state.commandNote == nil)
        await noRun.finish()
    }

    // MARK: Replies

    /// The same process's reply comes in as a reply: a live one carries the lease on to its new content, a not-live one
    /// revokes it, and none opens a lease that ran out. `applied` shows no note.
    @Test
    func test_reply_sameProcess_carriesOrRevokesTheLease_neverOpensOne() async throws {
        let paused = heldRun(.paused(heldStage))
        let live = Self.harness()
        let liveID = try await Self.tap(live)
        await live.store.send(.internal(.commandAnswered(
            sentID: liveID, Self.controlReply(liveID, .applied, runState(sequence: 3, run: paused))
        )))
        #expect(live.state.command == nil)
        #expect(live.state.run?.run == paused)
        #expect(live.state.lease != nil)
        #expect(live.state.commandNote == nil)
        await live.finish()

        let notLive = Self.harness()
        let notLiveID = try await Self.tap(notLive)
        await notLive.store.send(.internal(.commandAnswered(
            sentID: notLiveID, Self.controlReply(notLiveID, .applied, runState(sequence: 3, run: paused, live: false))
        )))
        #expect(notLive.state.lease == nil)
        await notLive.finish()

        // Tapped halfway through the lease, answered after its end and before the command's own timeout.
        let expired = Self.harness()
        await expired.advance(seconds: 5)
        let expiredID = try await Self.tap(expired)
        await expired.advance(seconds: 5)
        await expired.store.send(.internal(.commandAnswered(
            sentID: expiredID, Self.controlReply(expiredID, .applied, runState(sequence: 3, run: paused))
        )))
        #expect(expired.state.lease == nil)
        #expect(Self.control(expired) == nil)
        await expired.finish()
    }

    enum Outcome: CaseIterable, Sendable {
        case staleLive
        case busyLive
        case busyNotLive
        case unavailableNotLive
        case timedOutNotLive

        var result: WatchControlResult {
            switch self {
                case .staleLive: .stale
                case .busyLive, .busyNotLive: .busy
                case .unavailableNotLive: .unavailable
                case .timedOutNotLive: .timedOut
            }
        }

        var isLive: Bool {
            self == .staleLive || self == .busyLive
        }

        var note: WatchRemoteFeature.CommandNote {
            switch self {
                case .staleLive: .changed
                case .busyLive, .busyNotLive, .unavailableNotLive: .failed
                case .timedOutNotLive: .checking
            }
        }
    }

    @Test(arguments: Outcome.allCases)
    func test_reply_outcome_showsItsNote_andALiveBusyKeepsTheLeaseWithoutAsking(outcome: Outcome) async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)
        let requestsBefore = harness.requests
        await harness.store.send(.internal(.commandAnswered(
            sentID: id, Self.controlReply(id, outcome.result, runState(sequence: 3, run: runningRun(), live: outcome.isLive))
        )))

        #expect(harness.state.commandNote?.note == outcome.note)
        #expect((harness.state.lease != nil) == outcome.isLive)
        // With the lease kept nothing asks; without it, one refresh does.
        #expect(harness.requests == requestsBefore + (outcome.isLive ? 0 : 1))
        await harness.finish()
    }

    enum Envelope: CaseIterable, Sendable {
        case unreadable
        case anotherRequestsID
        case refreshsReply
    }

    @Test(arguments: Envelope.allCases)
    func test_reply_wrongEnvelope_endsTheCommandAsIncompatible(envelope: Envelope) async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)
        let state = runState(sequence: 3, run: runningRun())
        let answer: WatchReplyEnvelope = switch envelope {
            case .unreadable: .unreadable
            case .anotherRequestsID: Self.controlReply(UUID(watch: 77), .applied, state)
            case .refreshsReply: reply(id, state)
        }

        await harness.store.send(.internal(.commandAnswered(sentID: id, answer)))

        #expect(harness.state.command == nil)
        #expect(harness.state.problem == .incompatible(.phone))
        await harness.finish()
    }

    @Test
    func test_refreshAnsweredWithACommandsReply_isIncompatible_andDropsTheDueRenewal() async {
        var state = State.showing(runningRun(), inFlight: true)
        state.refresh.isRenewalDue = true
        let harness = RunHarness(state)

        await harness.store.send(.internal(.refreshAnswered(
            sentID: UUID(watch: 9), Self.controlReply(UUID(watch: 9), .applied, runState(sequence: 3, run: runningRun()))
        )))

        #expect(harness.state.problem == .incompatible(.phone))
        #expect(!harness.state.refresh.isRenewalDue)
        await harness.finish()
    }

    @Test(arguments: [
        (PhoneLinkError.timedOut, WatchRemoteFeature.CommandNote?.some(.checking)),
        (.failed, .checking),
        (.unreachable, .checking),
        (.inactive, .checking),
        (.companionMissing, .failed),
        (.payloadTooLarge, .failed),
        (.incompatible(peerSchemaVersion: 2), nil),
    ])
    func test_linkFailure_showsCheckingWhenTheCommandMayHaveLeft_andFailedWhenItCouldNot(
        error: PhoneLinkError,
        note: WatchRemoteFeature.CommandNote?
    ) async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)

        await harness.store.send(.internal(.commandFailed(sentID: id, error)))

        #expect(harness.state.command == nil)
        #expect(harness.state.commandNote?.note == note)
        if note == nil {
            #expect(harness.state.problem == .incompatible(.watch))
        }
        await harness.finish()
    }

    /// Tapped halfway through the lease, so it has run out when the command's own 10 s do: one refresh asks.
    @Test
    func test_commandTimeout_endsTheCommandWithChecking_andAsksOnceWithoutALease() async throws {
        let harness = RunHarness(.showing(runningRun(endsIn: 600), lease: true))
        await harness.advance(seconds: 5)
        _ = try await Self.tap(harness)
        let requestsBefore = harness.requests

        await harness.advance(seconds: 10)
        await harness.store.receive(\.internal.commandTimedOut)

        #expect(harness.state.command == nil)
        #expect(harness.state.commandNote?.note == .checking)
        #expect(harness.state.lease == nil)
        #expect(harness.requests == requestsBefore + 1)
        #expect(harness.state.refresh.inFlight != nil)
        await harness.finish()
    }

    private struct NotALinkError: Error {}

    /// The send itself fails outside the link: the command may have left, so it shows «Checking…».
    @Test
    func test_sendFailingOutsideTheLink_showsChecking() async throws {
        let harness = Self.harness()
        _ = try await Self.tap(harness)

        await harness.replies.fail(NotALinkError())
        await harness.store.receive(\.internal.commandFailed)

        #expect(harness.state.command == nil)
        #expect(harness.state.commandNote?.note == .checking)
        await harness.finish()
    }

    /// The watch moved on to another timer before the reply came: the outcome is not about the run it shows.
    @Test
    func test_reply_aboutACommandToAnotherTimer_showsNoNote() async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)
        await harness.store.send(.internal(.event(.message(runState(sequence: 3, run: runningRun(owner: 2))))))

        await harness.store.send(.internal(.commandAnswered(
            sentID: id, Self.controlReply(id, .stale, runState(sequence: 4, run: runningRun(owner: 2)))
        )))

        #expect(harness.state.command == nil)
        #expect(harness.state.commandNote == nil)
        await harness.finish()
    }

    @Test
    func test_oldCommandsReplyFailureOrTimeout_isIgnoredWhole() async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)
        let before = harness.state

        await harness.store.send(.internal(.commandAnswered(
            sentID: UUID(watch: 50), Self.controlReply(UUID(watch: 50), .stale, runState(sequence: 3, run: runningRun(stage: "Other")))
        )))
        await harness.store.send(.internal(.commandFailed(sentID: UUID(watch: 50), .companionMissing)))
        await harness.store.send(.internal(.commandTimedOut(sentID: UUID(watch: 50))))

        #expect(harness.state == before)
        #expect(harness.state.command?.id == id)
        await harness.finish()
    }

    /// A reply of another iPhone process is an unsolicited state: no lease, no note, no switch of process; it asks at
    /// most once per state, and a refresh in flight keeps the reason for one request after it.
    @Test(arguments: [false, true])
    func test_reply_anotherProcess_isUnsolicited_andAsksAtMostOnce(isRefreshInFlight: Bool) async throws {
        var state = State.showing(runningRun(), lease: true)
        if isRefreshInFlight {
            state.refresh.lastSerial += 1
            state.refresh.inFlight = .sent(UUID(watch: 9), serial: state.refresh.lastSerial)
        }
        let harness = RunHarness(state)
        let id = try await Self.tap(harness)
        let process = harness.state.order.processID
        let requestsBefore = harness.requests
        let other = runState(process: 2, sequence: 1, run: runningRun(stage: "Other"))

        await harness.store.send(.internal(.commandAnswered(sentID: id, Self.controlReply(id, .applied, other))))

        #expect(harness.state.order.processID == process)
        #expect(harness.state.run?.run == runningRun())
        #expect(harness.state.lease != nil)
        #expect(harness.state.commandNote == nil)
        if isRefreshInFlight {
            #expect(harness.requests == requestsBefore)
            #expect(harness.state.refresh.needsRefresh)
        } else {
            #expect(harness.requests == requestsBefore + 1)
        }

        // The same state again asks nothing more.
        let againID = try await Self.tap(harness)
        let requestsAfter = harness.requests
        await harness.store.send(.internal(.commandAnswered(sentID: againID, Self.controlReply(againID, .applied, other))))
        #expect(harness.requests == requestsAfter)
        await harness.finish()
    }

    enum AfterCommand: CaseIterable, Sendable {
        case noLease
        case noLeaseRetryScheduled
        case leaseHeld
        case refreshInFlight
        case wristLowered
    }

    /// One refresh after a command left the run without a lease, even with a run retry scheduled, which holds back the
    /// run's own reasons; none with a lease, with a refresh in flight, or with the wrist lowered.
    @Test(arguments: AfterCommand.allCases)
    func test_afterACommand_asksOnceOnlyWithoutALeaseOrARequest(after: AfterCommand) async throws {
        var state = State.showing(runningRun(), lease: true, inFlight: after == .refreshInFlight)
        state.refresh.isRetryScheduled = after == .noLeaseRetryScheduled
        let harness = RunHarness(state)
        let id = try await Self.tap(harness)
        if after == .wristLowered {
            await harness.store.send(.view(.luminanceChanged(isReduced: true)))
        }
        let requestsBefore = harness.requests
        let shouldAsk = after == .noLease || after == .noLeaseRetryScheduled

        await harness.store.send(.internal(.commandAnswered(
            sentID: id, Self.controlReply(id, .unavailable, runState(sequence: 3, run: runningRun(), live: after == .leaseHeld))
        )))

        #expect(harness.requests == requestsBefore + (shouldAsk ? 1 : 0))
        await harness.finish()
    }

    @Test
    func test_background_dropsTheCommandAndItsNote_andALateReplyChangesNothing() async throws {
        let harness = Self.harness()
        let id = try await Self.tap(harness)
        await harness.store.send(.view(.scenePhaseChanged(.background)))

        #expect(harness.state.command == nil)
        #expect(harness.state.commandNote == nil)
        let before = harness.state
        await harness.store.send(.internal(.commandAnswered(
            sentID: id, Self.controlReply(id, .stale, runState(sequence: 3, run: runningRun(stage: "Other")))
        )))
        #expect(harness.state == before)
        await harness.finish()
    }
}

extension WatchRemoteFeature.State {
    /// The note the run's screen shows.
    var runScreenNote: RunNote? {
        guard case let .run(screen) = screen else { return nil }
        return screen.note
    }
}
