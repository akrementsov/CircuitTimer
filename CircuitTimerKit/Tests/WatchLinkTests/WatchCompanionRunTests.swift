@testable import WatchLink

import Dependencies
import Foundation
import Testing
import TestSupport

/// A refresh about the running workout: it goes to the run's timer, is answered once within 5 s of its arrival, and
/// is live only after the timer's publication was numbered.
@Suite(.timeLimit(.minutes(1)))
struct WatchCompanionRunTests {
    private let link = FakeLink()
    private let clock = ManualClock()

    private func start() async -> WatchCompanion {
        let companion = await WatchCompanion.make(link: link, clock: clock)
        let events = link.transport.events()
        Task { await companion.run(events) }
        return companion
    }

    /// Sends a refresh and returns its first reply, with every reply its ticket got, so a test can look again later.
    private func refresh(_ number: Int = 7) async throws -> (envelope: WatchReplyEnvelope, answers: LockIsolated<[Data]>) {
        let request = try WireCoding.encode(WatchRequestEnvelope(requestID: UUID(link: number), request: .refresh(knownCatalogDigest: nil)))
        let answers = LockIsolated<[Data]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ticket = ReplyTicket { data in
                let isFirst = answers.withValue { answers in
                    answers.append(data)
                    return answers.count == 1
                }
                if isFirst { continuation.resume() }
            }
            link.events.value?.yield(.request(request, ticket))
        }
        return (try WireCoding.decode(WatchReplyEnvelope.self, from: answers.value[0]), answers)
    }

    private static func state(of envelope: WatchReplyEnvelope) throws -> PhoneState {
        guard case let .state(state) = envelope.reply else { throw ReplyWithoutState() }
        return state
    }

    private struct ReplyWithoutState: Error {}

    /// The companion with A's first stage published and A's timer subscribed.
    private func running() async -> (WatchCompanion, AsyncStream<WatchControlRequest>.AsyncIterator) {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))
        let requests = await companion.controlRequests(owner: owner(1))
        return (companion, requests.makeAsyncIterator())
    }

    @Test
    func test_refresh_timerPublishes_repliesLiveWithItsNumber_thenPushesItWithoutTheCatalog() async throws {
        var (companion, requests) = await running()
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())

        await companion.refreshHandled(
            owner: owner(1), requestID: request.id, publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )
        let (envelope, answers) = try await pending.value

        let state = try Self.state(of: envelope)
        #expect(answers.value.count == 1)
        #expect(envelope.requestID == UUID(link: 7))
        #expect(state.isRunLive)
        #expect(state.run == makeRun(stage: "A2"))
        let numbered = try #require(try link.writtenStates().last)
        #expect(state.sequence == numbered.sequence)
        await link.messages.wait { $0.count >= 3 }
        let pushed = try #require(try link.sentStates().last)
        #expect(pushed.sequence == numbered.sequence)
        #expect(pushed.catalog == nil)
        #expect(pushed.run == makeRun(stage: "A2"))
    }

    @Test
    func test_refresh_noTimerSubscribed_repliesNotLiveAtOnce() async throws {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun())

        // The clock never moves: a reply that waited for a timer would never come.
        let state = try Self.state(of: try await refresh().envelope)

        #expect(!state.isRunLive)
        #expect(state.run == makeRun())
    }

    @Test
    func test_refresh_timerSilentFor5Seconds_repliesNotLive() async throws {
        var (_, requests) = await running()
        let pending = Task { try await refresh() }
        _ = try #require(await requests.next())

        await clock.waitForStartedSleeps(1)
        clock.advance(by: WatchCompanion.timerWait)

        let state = try Self.state(of: try await pending.value.envelope)
        #expect(!state.isRunLive)
        #expect(state.run == makeRun(stage: "A1"))
    }

    @Test
    func test_refresh_timerAnswersNil_repliesNotLiveAndPublishesNothing() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())

        await companion.refreshHandled(owner: owner(1), requestID: request.id, publication: nil)

        #expect(try !Self.state(of: try await pending.value.envelope).isRunLive)
        #expect(link.contexts.value.count == 1)
    }

    @Test
    func test_refresh_publicationOfAnotherOwner_isIgnored() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())

        await companion.refreshHandled(
            owner: owner(1), requestID: request.id, publication: WatchRunPublication(revision: 2, run: makeRun(owner: 2))
        )

        #expect(try !Self.state(of: try await pending.value.envelope).isRunLive)
        #expect(try link.writtenStates().map(\.run) == [makeRun(stage: "A1")])
    }

    /// The timer answered in time, but its publication is numbered only after the 5 s: the reply is not live, and the
    /// publication still reaches the context and an open watch.
    @Test
    func test_refresh_numberingSlowerThanTheRest_repliesNotLive_andStillPublishes() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())
        await clock.waitForStartedSleeps(1)
        clock.advance(by: .seconds(4))
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)

        await companion.refreshHandled(
            owner: owner(1), requestID: request.id, publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )
        await gate.started.wait { $0 }
        // The wait for the numbering got the second left of the 5 s.
        await clock.waitForStartedSleeps(2)
        clock.advance(by: .seconds(1))

        #expect(try !Self.state(of: try await pending.value.envelope).isRunLive)
        gate.open()
        await link.contexts.wait { $0.count == 2 }
        await link.messages.wait { $0.count == 2 }
        #expect(try link.sentStates().last?.run == makeRun(stage: "A2"))
    }

    @Test
    func test_refresh_timersBufferFull_repliesNotLiveAtOnce() async throws {
        var (_, requests) = await running()
        try await withThrowingTaskGroup(of: PhoneState.self) { group in
            // The buffer keeps four requests nobody reads; the fifth does not fit.
            for number in 1...4 {
                group.addTask { try Self.state(of: try await refresh(number).envelope) }
            }
            await clock.waitForSleeps(4)

            let fifth = try Self.state(of: try await refresh(5).envelope)

            #expect(!fifth.isRunLive)
            clock.advance(by: WatchCompanion.timerWait)
            for try await waited in group {
                #expect(!waited.isRunLive)
            }
        }
        _ = await requests.next()
    }

    @Test
    func test_refresh_twoRequests_eachAnswerReachesItsOwnRequest() async throws {
        var (companion, requests) = await running()
        let first = Task { try await refresh(1) }
        let firstRequest = try #require(await requests.next())
        let second = Task { try await refresh(2) }
        let secondRequest = try #require(await requests.next())

        await companion.refreshHandled(owner: owner(1), requestID: secondRequest.id, publication: nil)
        await companion.refreshHandled(
            owner: owner(1), requestID: firstRequest.id, publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )

        let firstReply = try await first.value.envelope
        let secondReply = try await second.value.envelope
        #expect(firstReply.requestID == UUID(link: 1))
        #expect(try Self.state(of: firstReply).isRunLive)
        #expect(secondReply.requestID == UUID(link: 2))
        #expect(try !Self.state(of: secondReply).isRunLive)
    }

    @Test
    func test_newSubscription_answersTheOldOnesRequestNotLive_andALateAnswerOnlyPublishes() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())

        let replacement = await companion.controlRequests(owner: owner(1))

        let (envelope, answers) = try await pending.value
        #expect(try !Self.state(of: envelope).isRunLive)
        await companion.refreshHandled(
            owner: owner(1), requestID: request.id, publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )
        #expect(try link.writtenStates().last?.run == makeRun(stage: "A2"))
        // The late answer only published: the request was replied to once.
        #expect(answers.value.count == 1)
        _ = replacement
    }

    @Test
    func test_end_whileARequestWaits_repliesNotLive_andALateAnswerPublishesNothing() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await refresh() }
        let request = try #require(await requests.next())

        companion.markEnded(owner(1))
        await companion.end(owner: owner(1))

        #expect(try !Self.state(of: try await pending.value.envelope).isRunLive)
        await companion.refreshHandled(
            owner: owner(1), requestID: request.id, publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )
        let written = try link.writtenStates()
        #expect(written.map(\.run) == [makeRun(stage: "A1"), nil])
        #expect(try link.sentStates().last?.run == nil)
    }

    @Test
    func test_markEnded_isSynchronous_laterPublicationsAndSubscriptionsGetNothing() async throws {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))

        companion.markEnded(owner(1))

        await companion.publishRun(revision: 2, run: makeRun(stage: "A2"))
        #expect(link.contexts.value.count == 1)
        var requests = await companion.controlRequests(owner: owner(1)).makeAsyncIterator()
        #expect(await requests.next() == nil)
    }

    @Test
    func test_activation_heldWrite_doesNotHoldTheReplyToARequest() async throws {
        let companion = await start()
        link.snapshot.withValue { $0.canPublish = false }
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))
        link.snapshot.withValue { $0.canPublish = true }
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        let events = try #require(link.events.value)

        events.yield(.activated)
        await gate.started.wait { $0 }
        let reply = try Self.state(of: try await refresh().envelope)

        #expect(reply.catalog == .loaded(makeCatalog(1)))
        gate.open()
        await link.contexts.wait { $0.count == 1 }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OneAnswerTests {
    @Test
    func test_give_onlyTheFirstAnswerCounts_andWaitReturnsIt() async {
        let answer = OneAnswer<Int?>()

        #expect(answer.give(1))
        #expect(!answer.give(2))
        #expect(await answer.wait(timeout: .seconds(5), clock: ManualClock(), otherwise: nil) == 1)
    }

    @Test
    func test_wait_timeout_returnsTheFallback_andALateAnswerIsRefused() async {
        let clock = ManualClock()
        let answer = OneAnswer<Int?>()
        let waiting = Task { await answer.wait(timeout: .seconds(5), clock: clock, otherwise: nil) }
        await clock.waitForSleeps()

        clock.advance(by: .seconds(5))

        #expect(await waiting.value == nil)
        #expect(!answer.give(3))
    }

    @Test
    func test_wait_cancelledCaller_returnsTheFallbackAtOnce_andALateAnswerIsRefused() async {
        let clock = ManualClock()
        let answer = OneAnswer<Int?>()
        let waiting = Task { await answer.wait(timeout: .seconds(5), clock: clock, otherwise: nil) }
        await clock.waitForSleeps()

        // The clock never moves: only the cancellation ends the wait.
        waiting.cancel()

        #expect(await waiting.value == nil)
        #expect(!answer.give(3))
    }
}
