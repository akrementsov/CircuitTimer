@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing
import TestSupport
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// Pause and Resume from the watch: one rule with the card's commands, one pending command for both sources, and an
/// answer only to the command's own source. These tests pin the outcome and its route; the clock's and the record's
/// own effects are pinned by the card's exhaustive tests, so the store here is not exhaustive.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TimerWatchCommandTests {
    private static func command(
        _ id: Int,
        _ command: LiveActivityCommand,
        generation: Int = 3
    ) -> WorkoutTimerFeature.Action {
        .internal(.watchRequestReceived(WatchControlRequest(id: id, kind: .command(command, generation: generation))))
    }

    /// A store whose state took the watch's subscription first: commands need no card.
    private static func harness(
        _ state: WorkoutTimerFeature.State,
        generation: Int = 3,
        cardReady: Bool = false,
        isEnding: Bool = false
    ) -> TimerHarness {
        var state = state
        state.activityControls = WorkoutTimerFeature.ActivityControlState(
            isReady: cardReady, isEnding: isEnding, generation: generation
        )
        let timer = TimerHarness(state)
        timer.store.exhaustivity = .off
        return timer
    }

    /// The card's acknowledgements, which a watch command must never send.
    private static func recordCardAcknowledgements(_ timer: TimerHarness) -> LockIsolated<[LiveActivityControlResult]> {
        let results = LockIsolated<[LiveActivityControlResult]>([])
        timer.store.dependencies.liveActivity.requestHandled = { _, _, result in
            results.withValue { $0.append(result) }
        }
        return results
    }

    /// The card's drains wait until the test gives them an outcome. Every pass a command waits in starts a drain with a
    /// newer revision, and only the newest one counts, so the test answers every drain from a point on, or every one
    /// up to a revision.
    private final class HeldDrains: Sendable {
        struct Outcomes: Sendable {
            var byRevision: [Int: LiveActivitySyncResult.Outcome] = [:]
            var fromNow: LiveActivitySyncResult.Outcome?
        }

        let started = Observed<[Int]>([])
        let outcomes = Observed(Outcomes())

        /// Every drain waiting now or started later gets `outcome`.
        func answerFromNow(_ outcome: LiveActivitySyncResult.Outcome) {
            outcomes.withValue { $0.fromNow = outcome }
        }

        /// Every drain started up to `revision` gets `outcome`; later ones keep waiting.
        func answer(upTo revision: Int, _ outcome: LiveActivitySyncResult.Outcome) {
            let revisions = started.value.filter { $0 <= revision }
            outcomes.withValue { outcomes in
                for revision in revisions { outcomes.byRevision[revision] = outcome }
            }
        }

        /// Ends every drain still waiting, so no effect outlives the test.
        func release() {
            outcomes.withValue { $0.fromNow = $0.fromNow ?? .superseded }
        }
    }

    private static func holdDrains(_ timer: TimerHarness) -> HeldDrains {
        let drains = HeldDrains()
        let revisions = LockIsolated(0)
        timer.store.dependencies.liveActivity.nextRevision = { revisions.withValue { $0 += 1; return $0 } }
        timer.store.dependencies.liveActivity.sync = { _, _, _, _ in nil }
        timer.store.dependencies.liveActivity.syncWithResult = { _, revision, _, _ in
            drains.started.withValue { $0.append(revision) }
            await drains.outcomes.wait { $0.byRevision[revision] != nil || $0.fromNow != nil }
            let outcomes = drains.outcomes.value
            return LiveActivitySyncResult(outcome: outcomes.byRevision[revision] ?? outcomes.fromNow ?? .failed)
        }
        return drains
    }

    enum Applied: CaseIterable, Sendable {
        case pauseRunning
        case resumePaused
        case resumeAwaitingUser
    }

    @Test(arguments: Applied.allCases)
    func test_watchCommand_applies_raisesTheGeneration_andAnswersOnlyTheWatchOnceWithThisPassPublication(
        applied: Applied
    ) async {
        let (state, command): (WorkoutTimerFeature.State, LiveActivityCommand) = switch applied {
            case .pauseRunning: (.fixture(.running), .pause)
            case .resumePaused: (.fixture(.paused), .resume)
            case .resumeAwaitingUser: (.fixture(.awaitingUser, schedule: Schedules.withPause), .resume)
        }
        let timer = Self.harness(state)
        let card = Self.recordCardAcknowledgements(timer)

        await timer.store.send(Self.command(9, command))
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.store.state.snapshot.status == (command == .pause ? .paused : .running))
        #expect(timer.store.state.activityControls?.generation == 4)
        #expect(timer.store.state.activityControls?.pending == nil)
        let answer = timer.watch.controls.value
        #expect(answer.map(\.requestID) == [9])
        #expect(answer.first?.result == .applied)
        #expect(answer.first?.publication?.run.content.controlGeneration == 4)
        // The command's own pass published first; later passes (the record's write) publish again.
        #expect(answer.first?.publication == timer.watch.published.value.first)
        #expect(timer.watch.answers.value.isEmpty)
        #expect(card.value.isEmpty)
        await timer.cancelClockLoop()
    }

    @Test
    func test_watchCommand_staleGeneration_changesNothing_andAnswersStaleWithTheRun() async {
        let timer = Self.harness(.fixture(.running))

        await timer.store.send(Self.command(9, .pause, generation: 2))
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.store.state.snapshot.status == .running)
        #expect(timer.store.state.activityControls?.generation == 3)
        #expect(timer.watch.controls.value.first?.result == .stale)
        #expect(timer.watch.controls.value.first?.publication != nil)
        await timer.cancelClockLoop()
    }

    enum NotReady: CaseIterable, Sendable {
        case closing
        case clockNotStarted
        case ending
    }

    @Test(arguments: NotReady.allCases)
    func test_watchCommand_timerCannotTakeIt_isUnavailableOnce_withoutAPublicationWhileClosing(notReady: NotReady) async {
        var state: WorkoutTimerFeature.State = notReady == .clockNotStarted ? .fresh() : .fixture(.running)
        if notReady == .closing { state.isClosing = true }
        let timer = Self.harness(state, isEnding: notReady == .ending)

        await timer.store.send(Self.command(9, .pause))
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.watch.controls.value.map(\.result) == [.unavailable])
        #expect(timer.store.state.controlRefusal == nil)
        #expect(timer.store.state.activityControls?.pending == nil)
        if notReady != .ending {
            #expect(timer.watch.controls.value.first?.publication == nil)
        }
        await timer.store.skipInFlightEffects(strict: false)
    }

    @Test
    func test_watchTaskThenActivityTask_keepsThePendingCommand_andSubscribesTheCardOnce() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.isClosing = false
        let timer = TimerHarness(state)
        timer.store.exhaustivity = .off
        let subscriptions = LockIsolated(0)
        timer.store.dependencies.liveActivity.requests = { _ in
            subscriptions.withValue { $0 += 1 }
            return AsyncStream { _ in }
        }
        let drains = Self.holdDrains(timer)

        await timer.store.send(.view(.watchTask))
        #expect(timer.store.state.activityControls == WorkoutTimerFeature.ActivityControlState())
        await timer.store.send(.view(.activityTask))
        await timer.store.send(.internal(.activityRequestsReady))
        await timer.store.send(Self.command(9, .pause, generation: 0))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(.view(.activityTask))

        #expect(subscriptions.value == 1)
        #expect(timer.store.state.activityControls?.isActivitySubscribed == true)
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        drains.answerFromNow(.applied)
        await timer.watch.controls.wait { !$0.isEmpty }
        await timer.store.skipInFlightEffects(strict: false)
    }

    enum Drain: CaseIterable, Sendable {
        case unavailable
        case failed
        case deferred
    }

    /// The card's outcome never changes what the timer did for the watch, but the watch's answer waits for the drain
    /// that was started.
    @Test(arguments: Drain.allCases)
    func test_watchCommand_startedDrainFails_answersApplied_onlyAfterTheDrain(drain: Drain) async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        #expect(timer.watch.controls.value.isEmpty)
        let outcome: LiveActivitySyncResult.Outcome = switch drain {
            case .unavailable: .unavailable
            case .failed: .failed
            case .deferred: .deferred
        }
        drains.answerFromNow(outcome)
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        await timer.cancelClockLoop()
    }

    @Test
    func test_watchCommand_supersededDrain_waitsForTheNewerOne_andAnswersOnce() async throws {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        let superseded = try #require(timer.store.state.activityControls?.pending?.activityRevision)
        drains.answer(upTo: superseded, .superseded)
        await timer.store.receive(\.internal.activitySynchronized)
        #expect(timer.watch.controls.value.isEmpty)
        #expect(timer.store.state.activityControls?.pending?.activityResult == nil)
        // A later pass syncs again with a newer revision, which carries the command.
        await timer.store.send(.view(.notificationPreferencesChanged))
        drains.answerFromNow(.applied)
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        await timer.cancelClockLoop()
    }

    /// The card's subscription ends while the watch's command waits for a drain it started: the command still waits
    /// for that drain's result, then answers the watch once.
    @Test
    func test_activityRequestsEnded_duringAStartedDrain_keepsTheWatchCommand_untilTheDrainAnswers() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)
        let card = Self.recordCardAcknowledgements(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(.internal(.activityRequestsEnded))

        #expect(timer.store.state.activityControls?.isReady == false)
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        #expect(timer.store.state.activityControls?.pending?.activityResult == nil)
        #expect(timer.watch.controls.value.isEmpty)
        drains.answerFromNow(.applied)
        await timer.watch.controls.wait { !$0.isEmpty }
        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        #expect(card.value.isEmpty)
        await timer.cancelClockLoop()
    }

    /// A second command, from either source, never runs while one is held: `busy` until the held one stalls, then
    /// `unavailable`, logged once.
    @Test
    func test_secondCommand_whileOneIsHeld_isBusyThenUnavailable_andNeverApplies() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)
        let card = Self.recordCardAcknowledgements(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(Self.command(10, .resume, generation: 4))
        await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .resume, generation: 4))))
        #expect(timer.store.state.activityControls?.pending?.isStallLogged == false)

        await timer.clock.advance(by: LiveActivityControlTiming.stallLimit)
        await timer.store.send(Self.command(11, .resume, generation: 4))
        #expect(timer.store.state.activityControls?.pending?.isStallLogged == true)
        await timer.store.send(.internal(.activityRequestReceived(.init(id: 18, command: .resume, generation: 4))))

        #expect(timer.store.state.snapshot.status == .paused)
        await timer.watch.controls.wait { $0.count == 2 }
        #expect(timer.watch.controls.value.map(\.requestID) == [10, 11])
        #expect(timer.watch.controls.value.map(\.result) == [.busy, .unavailable])
        #expect(card.value == [.busy, .unavailable])
        #expect(timer.store.state.activityControls?.pending?.isStallLogged == true)
        drains.release()
        await timer.store.skipInFlightEffects(strict: false)
    }

    /// A watch command that outlived its pass stops waiting at the stall limit: with its drain still hung it stays the
    /// one held command; once the drain ends it is released without an answer, and the next command applies.
    @Test
    func test_watchCommand_pastTheStallLimit_staysHeldWhileItsDrainHangs_thenIsReleasedWithoutAnAnswer() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        #expect(timer.store.state.activityControls?.pending?.isStallScheduled == true)
        await timer.clock.advance(by: LiveActivityControlTiming.stallLimit)
        await timer.store.receive(\.internal.watchCommandStallLimitReached)

        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        drains.answerFromNow(.applied)
        // Older drains answer too and are ignored; the newest one releases the command.
        while timer.store.state.activityControls?.pending != nil {
            await timer.store.receive(\.internal.activitySynchronized)
        }

        #expect(timer.watch.controls.value.isEmpty)
        await timer.store.send(Self.command(10, .resume, generation: 4))
        await timer.watch.controls.wait { !$0.isEmpty }
        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        await timer.cancelClockLoop()
    }

    /// A late stall action of an earlier command decides nothing for the held one.
    @Test
    func test_lateStallAction_ofAnEarlierCommand_doesNotReleaseTheHeldOne() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(.internal(.watchCommandStallLimitReached(requestID: 1)))
        drains.answerFromNow(.applied)
        await timer.watch.controls.wait { !$0.isEmpty }
        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        await timer.cancelClockLoop()
    }

    /// A refresh while the watch's command waits is answered with this pass's publication and leaves the command held.
    @Test
    func test_refresh_whileACommandWaits_isAnsweredWithThisPass_andKeepsTheCommand() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)

        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(.internal(.watchRequestReceived(WatchControlRequest(id: 12, kind: .refresh))))
        await timer.watch.refreshed.wait { $0 }

        #expect(timer.watch.answers.value.map(\.requestID) == [12])
        #expect(timer.watch.answers.value.first?.publication?.run.owner == timerID)
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        drains.answerFromNow(.applied)
        await timer.watch.controls.wait { !$0.isEmpty }
        await timer.cancelClockLoop()
    }
}
