@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

/// An accepted Start asks for its run every `startRunPoll`, so a lost message or context does not end in «Check the
/// iPhone» while the run is already published.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartPollTests {
    /// A harness whose selected workout is accepted by the iPhone; the Start's reply carries no run.
    private func accepted() async -> RunHarness {
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        let entry = watchCatalog("Morning").entries[0]
        state.path.append(.selected(id: entry.id, fingerprint: entry.scheduleFingerprint))
        let harness = RunHarness(state)
        await harness.store.send(.view(.startButtonTapped))
        await harness.replies.answer { id in
            WatchReplyEnvelope(requestID: id, reply: .start(.accepted(asksOnPhone: true), runState(sequence: 1, run: nil)))
        }
        await harness.store.receive(\.internal.startAnswered)
        #expect(harness.state.start?.stage == .waiting(asksOnPhone: true))
        return harness
    }

    /// The refreshes the reducer started, counted synchronously: the send itself runs in an effect, which a busy
    /// runner may not have reached yet.
    private func refreshes(_ harness: RunHarness) -> Int {
        harness.requests
    }

    @Test
    func test_startPoll_noPublication_refreshReplyShowsRunAndEndsWait() async {
        let harness = await accepted()
        let run = runningRun(endsIn: 30)

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        #expect(refreshes(harness) == 1)
        await harness.replies.answer(runState(sequence: 2, run: run))
        await harness.store.receive(\.internal.refreshAnswered)

        #expect(harness.state.start == nil)
        #expect(harness.state.startStatus == nil)
        #expect(harness.state.run?.run == run)
        #expect(harness.state.lease != nil)
        await harness.finish()
    }

    @Test
    func test_startPoll_repliesWithoutRun_asksEveryFiveSecondsThenSaysCheckPhone() async {
        let harness = await accepted()

        for second in stride(from: 5, through: 30, by: 5) {
            await harness.advance(seconds: 5)
            await harness.store.receive(\.internal.startPollDue)
            #expect(refreshes(harness) == second / 5)
            await harness.replies.answer(runState(sequence: 1 + second / 5, run: nil))
            await harness.store.receive(\.internal.refreshAnswered)
        }
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startTimedOut)
        #expect(harness.state.start == nil)
        #expect(harness.state.startNote == .checkPhone)

        await harness.advance(seconds: 20)
        #expect(refreshes(harness) == 6)
        await harness.finish()
    }

    @Test
    func test_startPoll_requestInFlight_sendsNoSecondRequest() async {
        let harness = await accepted()

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)

        #expect(refreshes(harness) == 1)
        #expect(harness.state.start != nil)
        await harness.finish()
    }

    @Test
    func test_startPoll_afterFailureWithRetry_asksOnlyThroughTheRetry() async {
        let harness = await accepted()

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.replies.fail(PhoneLinkError.unreachable)
        await harness.store.receive(\.internal.refreshFailed)
        #expect(harness.state.refresh.isRetryScheduled)
        await harness.advance(seconds: 5)
        // The retry and the poll come due together; whichever goes first, one request goes.
        await harness.store.receive(\.internal.retryDue)

        #expect(refreshes(harness) == 2)
        await harness.finish()
    }

    @Test
    func test_startPoll_sessionInactive_asksAgainAtTheNextPoll() async {
        let harness = await accepted()

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.replies.fail(PhoneLinkError.inactive)
        await harness.store.receive(\.internal.refreshFailed)
        #expect(harness.state.problem == .unreachable)
        #expect(!harness.state.refresh.isRetryScheduled)
        // Activated again, the status still reads reachable: no change of `canSend` asks, so the poll must.
        await harness.store.send(.internal(.event(.status(reachable))))
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        #expect(refreshes(harness) == 2)
        await harness.replies.answer(runState(sequence: 2, run: runningRun()))
        await harness.store.receive(\.internal.refreshAnswered)

        #expect(harness.state.start == nil)
        #expect(harness.state.run != nil)
        await harness.finish()
    }

    @Test
    func test_startPoll_companionMissing_doesNotAsk() async {
        let harness = await accepted()

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.replies.fail(PhoneLinkError.companionMissing)
        await harness.store.receive(\.internal.refreshFailed)
        #expect(harness.state.problem == .companionMissing)
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)

        #expect(refreshes(harness) == 1)
        #expect(harness.state.start != nil)
        await harness.finish()
    }

    @Test
    func test_startPoll_wristLowered_stillAsks() async {
        let harness = await accepted()

        await harness.store.send(.view(.luminanceChanged(isReduced: true)))
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)

        #expect(refreshes(harness) == 1)
        await harness.finish()
    }

    @Test
    func test_startPoll_whileSending_doesNotAsk() async {
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        let entry = watchCatalog("Morning").entries[0]
        state.path.append(.selected(id: entry.id, fingerprint: entry.scheduleFingerprint))
        let harness = RunHarness(state)

        await harness.store.send(.view(.startButtonTapped))
        await harness.advance(seconds: 9)

        #expect(refreshes(harness) == 0)
        #expect(harness.state.start?.stage == .sending)
        await harness.finish()
    }

    @Test
    func test_startPoll_olderRequestOrGeneration_changesNothing() async {
        let harness = await accepted()
        let start = harness.state.start

        await harness.store.send(.internal(.startPollDue(sentID: UUID(watch: 99), generation: 1)))
        await harness.store.send(.internal(.startPollDue(sentID: UUID(0), generation: 0)))

        #expect(refreshes(harness) == 0)
        #expect(harness.state.start == start)
        await harness.finish()
    }

    @Test
    func test_startPoll_runArrivesByMessage_endsWaitWithoutPolling() async {
        let harness = await accepted()

        await harness.advance(seconds: 2)
        await harness.store.send(.internal(.event(.message(runState(sequence: 2, run: runningRun())))))
        #expect(harness.state.start == nil)
        // The run without a lease asks once, as any shown run does; the poll adds nothing.
        #expect(refreshes(harness) == 1)
        await harness.advance(seconds: 6)

        #expect(refreshes(harness) == 1)
        await harness.finish()
    }

    @Test
    func test_startPoll_replyFromNewPhoneProcess_switchesAndShowsRun() async {
        let harness = await accepted()
        let run = runningRun(owner: 2)

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.replies.answer(runState(process: 2, sequence: 1, run: run))
        await harness.store.receive(\.internal.refreshAnswered)

        #expect(harness.state.order.processID == UUID(watch: 102))
        #expect(harness.state.run?.run == run)
        #expect(harness.state.start == nil)
        await harness.finish()
    }

    @Test
    func test_startPoll_replyOvertakenByMessage_asksAgainOnce() async {
        let harness = await accepted()

        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startPollDue)
        await harness.store.send(.internal(.event(.message(runState(sequence: 3, run: runningRun(stage: "Rest"))))))
        #expect(harness.state.start == nil)
        #expect(refreshes(harness) == 1)
        await harness.replies.answer(runState(sequence: 2, run: runningRun()))
        await harness.store.receive(\.internal.refreshAnswered)

        #expect(refreshes(harness) == 2)
        await harness.finish()
    }

    @Test
    func test_startPoll_lateRunAfterTimeout_showsWithoutPolling() async {
        let harness = await accepted()
        for second in stride(from: 5, through: 30, by: 5) {
            await harness.advance(seconds: 5)
            await harness.store.receive(\.internal.startPollDue)
            await harness.replies.answer(runState(sequence: 1 + second / 5, run: nil))
            await harness.store.receive(\.internal.refreshAnswered)
        }
        await harness.advance(seconds: 5)
        await harness.store.receive(\.internal.startTimedOut)

        await harness.store.send(.internal(.event(.message(runState(sequence: 9, run: runningRun(endsIn: 60))))))
        #expect(harness.state.run != nil)
        #expect(harness.state.startNote == nil)
        let afterRun = refreshes(harness)
        await harness.replies.answer(runState(sequence: 10, run: runningRun(endsIn: 60)))
        await harness.store.receive(\.internal.refreshAnswered)
        await harness.advance(seconds: 4)

        #expect(refreshes(harness) == afterRun)
        await harness.finish()
    }

    @Test
    func test_startPoll_appLeaves_cancelsPoll() async {
        let harness = await accepted()

        await harness.advance(seconds: 3)
        await harness.store.send(.view(.scenePhaseChanged(.background)))
        await harness.store.send(.view(.scenePhaseChanged(.active)))
        await harness.store.receive(\.internal.statusRead)
        let afterReturn = refreshes(harness)
        await harness.advance(seconds: 4)

        #expect(harness.state.start == nil)
        #expect(refreshes(harness) == afterReturn)
        await harness.finish()
    }
}
