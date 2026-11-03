@testable import WorkoutTimerFeature

import BackgroundNotifications
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
        isEnding: Bool = false,
        notifications: Bool = false
    ) -> TimerHarness {
        var state = state
        state.activityControls = WorkoutTimerFeature.ActivityControlState(
            isReady: cardReady, isEnding: isEnding, generation: generation
        )
        let timer = TimerHarness(state, notifications: notifications)
        timer.store.exhaustivity = .off
        return timer
    }

    /// The card's acknowledgements, which a watch command must never send.
    private static func recordCardAcknowledgements(_ timer: TimerHarness) -> Observed<[LiveActivityControlResult]> {
        let results = Observed<[LiveActivityControlResult]>([])
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

        /// Drains started from now on wait again; those already answered stay answered.
        func holdFromNow() {
            outcomes.withValue { $0.fromNow = nil }
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

    /// A timer whose run has background notifications to schedule.
    private static func notifying(_ phase: TimerPhase) -> WorkoutTimerFeature.State {
        var state = WorkoutTimerFeature.State.fixture(phase)
        state.notifications.access = .authorized
        state.$isSoundOn = SharedReader(value: false)
        state.notifications.projection = state.notificationProjection(at: origin, language: "en")
        return state
    }

    /// The notifications' syncs wait until the test lets them finish with `report`.
    private static func holdNotifications(
        _ timer: TimerHarness,
        report: NotificationSyncReport = NotificationSyncReport()
    ) -> Observed<Bool> {
        let finished = Observed(false)
        timer.store.dependencies.backgroundNotifications.sync = { _, _, _ in
            await finished.wait { $0 }
            return report
        }
        return finished
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

    /// The watch's command goes through the same pass as the card's: the same assertions and the same record write.
    @Test
    func test_watchCommand_takesTheSameAssertionsAndWriteAsTheCardsCommand() async {
        let card = Self.harness(.fixture(.running), cardReady: true)
        Self.holdDrains(card).answerFromNow(.applied)
        await card.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .pause, generation: 3))))
        let watch = Self.harness(.fixture(.running), cardReady: true)
        Self.holdDrains(watch).answerFromNow(.applied)
        await watch.store.send(Self.command(9, .pause))

        #expect(watch.assertions.value.count == card.assertions.value.count)
        #expect(!watch.assertions.value.isEmpty)
        #expect(watch.store.state.run == card.store.state.run)
        // The record each pass asked for is the one written.
        await card.store.receive(\.internal.recordWritten)
        await watch.store.receive(\.internal.recordWritten)
        #expect(!watch.writes.value.isEmpty)
        #expect(watch.writes.value.first == card.writes.value.first)
        await card.cancelClockLoop()
        await watch.cancelClockLoop()
    }

    /// The watch's command waits for the notifications its pass required, like the card's, and a partial failure
    /// leaves it applied.
    @Test
    func test_watchCommand_waitsForTheNotifications_andStaysAppliedWhenSomeFail() async {
        let timer = Self.harness(Self.notifying(.paused), notifications: true)
        let notifications = Self.holdNotifications(timer, report: NotificationSyncReport(failed: 1))

        await timer.store.send(Self.command(9, .resume))
        #expect(timer.store.state.snapshot.status == .running)
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        #expect(timer.watch.controls.value.isEmpty)
        notifications.setValue(true)
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.watch.controls.value.map(\.result) == [.applied])
        // The store's state takes the actions its effects sent only as the test receives them.
        await timer.store.skipReceivedActions(strict: false)
        #expect(timer.store.state.notifications.hasSchedulingFailed)
        await timer.cancelClockLoop()
    }

    /// A watch command whose drain answered but whose notifications hang is released at the stall limit without an
    /// answer; one millisecond before it, finishing notifications still answer it.
    @Test(arguments: [false, true])
    func test_watchCommand_withItsNotificationsPending_isReleasedOnlyAtTheStallLimit(reachesTheLimit: Bool) async {
        let timer = Self.harness(Self.notifying(.running), cardReady: true, notifications: true)
        let drains = Self.holdDrains(timer)
        let notifications = Self.holdNotifications(timer)
        drains.answerFromNow(.applied)

        await timer.store.send(Self.command(9, .pause))
        while let pending = timer.store.state.activityControls?.pending, pending.activityResult == nil {
            await timer.store.receive(\.internal.activitySynchronized)
        }
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))

        if reachesTheLimit {
            await timer.clock.advance(by: LiveActivityControlTiming.stallLimit)
            await timer.store.receive(\.internal.watchCommandStallLimitReached)
            #expect(timer.store.state.activityControls?.pending == nil)
            #expect(timer.watch.controls.value.isEmpty)
            notifications.setValue(true)
        } else {
            await timer.clock.advance(by: LiveActivityControlTiming.stallLimit - .milliseconds(1))
            notifications.setValue(true)
            await timer.watch.controls.wait { !$0.isEmpty }
            #expect(timer.watch.controls.value.map(\.result) == [.applied])
        }
        await timer.cancelClockLoop()
    }

    /// The watch's commands need no card, but a closing timer that the watch subscribes first starts ending.
    @Test
    func test_watchTask_ofAClosingTimer_createsTheControlsEnding() async {
        var state = WorkoutTimerFeature.State.fixture(.running)
        state.isClosing = true
        let timer = TimerHarness(state)
        timer.store.exhaustivity = .off

        await timer.store.send(.view(.watchTask))

        #expect(timer.store.state.activityControls?.isEnding == true)
        await timer.store.skipInFlightEffects(strict: false)
    }

    /// The card's command is held first: the watch's is `busy`, and the card is not answered for it.
    @Test
    func test_watchCommand_whileACardCommandIsHeld_isBusy() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)
        let card = Self.recordCardAcknowledgements(timer)

        await timer.store.send(.internal(.activityRequestReceived(.init(id: 17, command: .pause, generation: 3))))
        await drains.started.wait { !$0.isEmpty }
        await timer.store.send(Self.command(9, .resume, generation: 4))
        await timer.watch.controls.wait { !$0.isEmpty }

        #expect(timer.watch.controls.value.map(\.result) == [.busy])
        #expect(timer.store.state.activityControls?.pending?.source == .liveActivity(requestID: 17))
        // The card gets its own answer once its drain does, and nothing for the watch's command.
        drains.answerFromNow(.applied)
        await card.wait { !$0.isEmpty }
        #expect(card.value == [.applied])
        #expect(timer.watch.controls.value.count == 1)
        await timer.cancelClockLoop()
    }

    /// After a command is answered, the stall action of that command decides nothing for the next one.
    @Test
    func test_lateStallAction_ofAnAnsweredCommand_doesNotReleaseTheNextOne() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)
        drains.answerFromNow(.applied)
        await timer.store.send(Self.command(9, .pause))
        await timer.watch.controls.wait { !$0.isEmpty }
        await timer.store.skipReceivedActions(strict: false)
        #expect(timer.store.state.activityControls?.pending == nil)

        drains.holdFromNow()
        await timer.store.send(Self.command(10, .resume, generation: 4))
        await timer.store.send(.internal(.watchCommandStallLimitReached(requestID: 9)))

        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 10))
        #expect(timer.watch.controls.value.map(\.requestID) == [9])
        drains.release()
        await timer.store.skipInFlightEffects(strict: false)
    }

    /// The stall limit counts from the command's admission: a later pass while it is held does not postpone it.
    @Test
    func test_watchCommand_stallLimit_countsFromTheAdmission_throughLaterPasses() async {
        let timer = Self.harness(.fixture(.running), cardReady: true)
        let drains = Self.holdDrains(timer)
        await timer.store.send(Self.command(9, .pause))
        await drains.started.wait { !$0.isEmpty }

        await timer.clock.advance(by: .seconds(4))
        await timer.store.send(.view(.notificationPreferencesChanged))
        await timer.clock.advance(by: LiveActivityControlTiming.stallLimit - .seconds(4))
        await timer.store.receive(\.internal.watchCommandStallLimitReached)

        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        drains.release()
        await timer.store.skipInFlightEffects(strict: false)
    }

    /// A watch command already past the stall limit when its wait is scheduled stops waiting at once.
    @Test
    func test_watchCommand_pastTheStallLimitWhenItsWaitIsScheduled_stopsWaitingAtOnce() async {
        var state = WorkoutTimerFeature.State.fixture(.paused)
        // Admitted at the test clock's start, which every fresh test clock shares.
        state.activityControls = WorkoutTimerFeature.ActivityControlState(
            isReady: true,
            generation: 4,
            pending: WorkoutTimerFeature.PendingActivityControl(
                source: .watch(requestID: 9), result: .applied, admittedAt: MonotonicInstant(now: TestClock<Duration>())
            )
        )
        let timer = TimerHarness(state)
        timer.store.exhaustivity = .off
        let drains = Self.holdDrains(timer)
        await timer.clock.advance(by: LiveActivityControlTiming.stallLimit + .seconds(1))

        await timer.store.send(.view(.notificationPreferencesChanged))
        await drains.started.wait { !$0.isEmpty }
        #expect(timer.store.state.activityControls?.pending?.isStallScheduled == true)
        await timer.clock.advance()
        await timer.store.receive(\.internal.watchCommandStallLimitReached)

        // Its drain hangs, so it stays held; once the drain ends it is released without an answer.
        #expect(timer.store.state.activityControls?.pending?.source == .watch(requestID: 9))
        drains.answerFromNow(.applied)
        while timer.store.state.activityControls?.pending != nil {
            await timer.store.receive(\.internal.activitySynchronized)
        }
        #expect(timer.watch.controls.value.isEmpty)
        await timer.store.skipInFlightEffects(strict: false)
    }
}
