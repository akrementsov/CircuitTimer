@testable import WatchLink

import Dependencies
import Foundation
import Testing
import TestSupport
import WorkoutActivity
import WorkoutDomain

/// A Pause or Resume from the watch: it goes to the run's timer through `CommandGate`, is answered once within 5 s of
/// its arrival, and says `applied` or `stale` only with the live state the timer published for it.
@Suite(.timeLimit(.minutes(1)))
struct WatchCompanionCommandTests {
    private let link = FakeLink()
    private let clock = ManualClock()

    private func start() async -> WatchCompanion {
        let companion = await WatchCompanion.make(link: link, clock: clock)
        let events = link.transport.events()
        Task { await companion.run(events) }
        return companion
    }

    /// The companion with A's first stage published and A's timer subscribed.
    private func running() async -> (WatchCompanion, AsyncStream<WatchControlRequest>.AsyncIterator) {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))
        let requests = await companion.controlRequests(owner: owner(1))
        return (companion, requests.makeAsyncIterator())
    }

    private struct Reply {
        let requestID: UUID?
        let result: WatchControlResult
        let state: PhoneState
        /// Every reply the request's ticket got.
        let answers: LockIsolated<[Data]>
    }

    private struct NotAControlReply: Error {}

    /// Sends a command of the watch and returns its first reply.
    private func command(
        _ number: Int = 7,
        owner commandOwner: UUID = owner(1),
        _ command: LiveActivityCommand = .pause,
        generation: Int = 3
    ) async throws -> Reply {
        let request = WatchRequest.control(owner: commandOwner, command: command, generation: generation, knownCatalogDigest: nil)
        let data = try WireCoding.encode(WatchRequestEnvelope(requestID: UUID(link: number), request: request))
        let answers = LockIsolated<[Data]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ticket = ReplyTicket { data in
                let isFirst = answers.withValue { answers in
                    answers.append(data)
                    return answers.count == 1
                }
                if isFirst { continuation.resume() }
            }
            link.events.value?.yield(.request(data, ticket))
        }
        let envelope = try WireCoding.decode(WatchReplyEnvelope.self, from: answers.value[0])
        guard case let .control(result, state) = envelope.reply else { throw NotAControlReply() }
        return Reply(requestID: envelope.requestID, result: result, state: state, answers: answers)
    }

    static func publication(_ revision: Int = 2, stage: String = "A2", owner ownerNumber: Int = 1) -> WatchRunPublication {
        WatchRunPublication(revision: revision, run: makeRun(owner: ownerNumber, stage: stage))
    }

    @Test(arguments: [
        (LiveActivityControlResult.applied, WatchControlResult.applied),
        (.stale, .stale),
        (.busy, .busy),
        (.timedOut, .timedOut),
        (.unavailable, .unavailable),
        (.failed, .unavailable),
        (.cancelled, .unavailable),
        (.orphanEnded, .unavailable),
    ])
    func test_controlResult_fromTheTimersResult_keepsWhatTheWatchShows(timer: LiveActivityControlResult, watch: WatchControlResult) {
        #expect(WatchControlResult(timer) == watch)
    }

    @Test
    func test_command_reachesTheTimer_withItsCommandAndGeneration() async throws {
        var (_, requests) = await running()
        let pending = Task { try await command(7, .resume, generation: 5) }

        let request = try #require(await requests.next())

        #expect(request.kind == .command(.resume, generation: 5))
        await clock.waitForStartedSleeps(1)
        clock.advance(by: WatchCompanion.timerWait)
        _ = try await pending.value
    }

    @Test(arguments: [LiveActivityControlResult.applied, .stale])
    func test_command_timerAnswersWithItsPublication_repliesLiveWithItsNumber(result: LiveActivityControlResult) async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command() }
        let request = try #require(await requests.next())

        await companion.controlHandled(owner: owner(1), requestID: request.id, result: result, publication: Self.publication())
        let reply = try await pending.value

        #expect(reply.requestID == UUID(link: 7))
        #expect(reply.result == WatchControlResult(result))
        #expect(reply.state.isRunLive)
        #expect(reply.state.run == makeRun(stage: "A2"))
        #expect(try reply.state.sequence == link.writtenStates().last?.sequence)
        #expect(reply.answers.value.count == 1)
    }

    enum Refusal: CaseIterable, Sendable {
        case anotherOwner
        case endedOwner
        case noSubscription
    }

    @Test(arguments: Refusal.allCases)
    func test_command_noTimerCanTakeIt_isUnavailableAtOnce(refusal: Refusal) async throws {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))
        var commandOwner = owner(1)
        switch refusal {
            case .anotherOwner:
                _ = await companion.controlRequests(owner: owner(1))
                commandOwner = owner(2)
            case .endedOwner:
                _ = await companion.controlRequests(owner: owner(1))
                companion.markEnded(owner(1))
            case .noSubscription:
                break
        }

        // The clock never moves: a reply that waited for a timer would never come.
        let reply = try await command(owner: commandOwner)

        #expect(reply.result == .unavailable)
        #expect(!reply.state.isRunLive)
    }

    /// A command whose 5 s ran out before its task started reaches no timer: the watch is told it was not applied.
    @Test
    func test_command_arrivedPastItsWaitBeforeItsTaskRan_isUnavailable_andNeverReachesTheTimer() async throws {
        var (companion, requests) = await running()
        let arrival = MonotonicInstant(now: clock)
        clock.advance(by: WatchCompanion.timerWait)

        let (result, state) = await companion.commandState(
            owner: owner(1), command: .pause, generation: 3, knownCatalogDigest: nil, arrival: arrival
        )

        #expect(result == .unavailable)
        #expect(!state.isRunLive)
        // It took no number and no place in the timer's stream: the next command, of another kind, is the first the timer
        // reads.
        let later = Task { try await command(8, .resume, generation: 5) }
        let next = try #require(await requests.next())
        #expect(next.id == 1)
        #expect(next.kind == .command(.resume, generation: 5))
        await clock.waitForStartedSleeps(1)
        clock.advance(by: WatchCompanion.timerWait)
        _ = try await later.value
    }

    enum Unconfirmed: CaseIterable, Sendable {
        case appliedWithoutPublication
        case staleWithoutPublication
        case appliedWithAnotherOwnersPublication
        case busyWithoutPublication
        case unavailableWithoutPublication

        var timerResult: LiveActivityControlResult {
            switch self {
                case .appliedWithoutPublication, .appliedWithAnotherOwnersPublication: .applied
                case .staleWithoutPublication: .stale
                case .busyWithoutPublication: .busy
                case .unavailableWithoutPublication: .unavailable
            }
        }

        var publication: WatchRunPublication? {
            self == .appliedWithAnotherOwnersPublication ? WatchCompanionCommandTests.publication(owner: 2) : nil
        }

        var watchResult: WatchControlResult {
            switch self {
                case .appliedWithoutPublication, .staleWithoutPublication, .appliedWithAnotherOwnersPublication: .timedOut
                case .busyWithoutPublication: .busy
                case .unavailableWithoutPublication: .unavailable
            }
        }
    }

    /// A command the timer may have applied is never answered as refused when no live state can go with it.
    @Test(arguments: Unconfirmed.allCases)
    func test_command_noLiveStateFromTheTimer_timesOutAnAppliedOne_andKeepsTheRest(case: Unconfirmed) async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command() }
        let request = try #require(await requests.next())
        await companion.controlHandled(
            owner: owner(1), requestID: request.id, result: `case`.timerResult, publication: `case`.publication
        )
        let reply = try await pending.value

        #expect(reply.result == `case`.watchResult)
        #expect(!reply.state.isRunLive)
    }

    /// The timer applied the command, but its publication is numbered only after the 5 s: no live state, so the
    /// watch is told the iPhone does not know.
    @Test
    func test_command_appliedButNumberedAfterTheWait_timesOut() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command() }
        let request = try #require(await requests.next())
        await clock.waitForStartedSleeps(1)
        clock.advance(by: .seconds(4))
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)

        await companion.controlHandled(owner: owner(1), requestID: request.id, result: .applied, publication: Self.publication())
        await gate.started.wait { $0 }
        await clock.waitForStartedSleeps(2)
        clock.advance(by: .seconds(1))

        let reply = try await pending.value
        #expect(reply.result == .timedOut)
        #expect(!reply.state.isRunLive)
    }

    @Test
    func test_command_timersBufferFull_timesOutWithoutReachingIt() async throws {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))
        var requests = await companion.controlRequests(owner: owner(1)).makeAsyncIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // The buffer keeps four refreshes nobody reads; the command does not fit.
            for number in 1...4 {
                group.addTask {
                    let envelope = WatchRequestEnvelope(requestID: UUID(link: number), request: .refresh(knownCatalogDigest: nil))
                    let data = try WireCoding.encode(envelope)
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        link.events.value?.yield(.request(data, ReplyTicket { _ in continuation.resume() }))
                    }
                }
            }
            await clock.waitForSleeps(4)

            let reply = try await command(5)

            #expect(reply.result == .timedOut)
            #expect(!reply.state.isRunLive)
            // The buffer holds the refreshes' numbers 1–4, so the command took 5.
            var buffered: [Int] = []
            for _ in 1...4 {
                buffered.append(try #require(await requests.next()).id)
            }
            #expect(buffered == [1, 2, 3, 4])
            // No ticket waits for it: an answer by its number only publishes.
            await companion.controlHandled(owner: owner(1), requestID: 5, result: .applied, publication: Self.publication())
            #expect(try link.writtenStates().last?.run == makeRun(stage: "A2"))
            clock.advance(by: WatchCompanion.timerWait)
            try await group.waitForAll()
        }
    }

    @Test
    func test_command_timersStreamTerminated_isUnavailable() async throws {
        let companion = await start()
        await companion.publishRun(revision: 1, run: makeRun(stage: "A1"))
        let requests = await companion.controlRequests(owner: owner(1))
        // The timer stops reading: its stream terminates before the actor hears of it.
        let reader = Task { for await _ in requests {} }
        reader.cancel()
        await reader.value

        let reply = try await command()

        #expect(reply.result == .unavailable)
        #expect(!reply.state.isRunLive)
    }

    @Test
    func test_command_timerSilentFor5Seconds_timesOut_andALateAnswerOnlyPublishes() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command() }
        let request = try #require(await requests.next())

        await clock.waitForStartedSleeps(1)
        clock.advance(by: WatchCompanion.timerWait)
        let reply = try await pending.value
        await companion.controlHandled(owner: owner(1), requestID: request.id, result: .applied, publication: Self.publication())

        #expect(reply.result == .timedOut)
        #expect(!reply.state.isRunLive)
        #expect(try link.writtenStates().last?.run == makeRun(stage: "A2"))
        #expect(reply.answers.value.count == 1)
    }

    @Test
    func test_closeGate_answersAHandedOverCommandTimedOut_andRefusesTheNext() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command(1) }
        _ = try #require(await requests.next())

        companion.closeGate()

        let reply = try await pending.value
        #expect(reply.result == .timedOut)
        #expect(!reply.state.isRunLive)
        let next = try await command(2)
        #expect(next.result == .unavailable)
        // The ledger's gate closed with it: a later publication writes nothing.
        let written = try link.writtenStates().count
        await companion.publishRun(revision: 5, run: makeRun(stage: "A5"))
        #expect(try link.writtenStates().count == written)
    }

    /// A replaced subscription answers the old one's command as unknown; the new one takes the next command, and the
    /// old stream's late termination leaves the new subscription and its command alone.
    @Test
    func test_newSubscription_oldCommandTimesOut_andTheNewOneKeepsItsCommand() async throws {
        var (companion, oldRequests) = await running()
        let old = Task { try await command(1) }
        _ = try #require(await oldRequests.next())

        var newRequests = await companion.controlRequests(owner: owner(1)).makeAsyncIterator()
        let oldReply = try await old.value
        #expect(await oldRequests.next() == nil)
        // The old stream's termination callback runs on its own task, at no known point: make its call here.
        await companion.subscriptionEnded(owner: owner(1), subscriptionID: 1)
        let new = Task { try await command(2) }
        let newRequest = try #require(await newRequests.next())
        await companion.controlHandled(owner: owner(1), requestID: newRequest.id, result: .applied, publication: Self.publication())

        #expect(oldReply.result == .timedOut)
        let newReply = try await new.value
        #expect(newReply.result == .applied)
        #expect(newReply.state.isRunLive)
    }

    /// The timer answers a command its ended subscription already answered as unknown: its own run is published, a
    /// run of another timer is not, and the watch got one reply.
    @Test
    func test_lateAnswer_afterTheSubscriptionEnded_publishesOnlyItsOwnersRun() async throws {
        var (companion, requests) = await running()
        let pending = Task { try await command(1) }
        let request = try #require(await requests.next())
        _ = await companion.controlRequests(owner: owner(1))
        let reply = try await pending.value
        #expect(reply.result == .timedOut)

        await companion.controlHandled(owner: owner(1), requestID: request.id, result: .applied, publication: Self.publication(owner: 2))
        #expect(try link.writtenStates().last?.run == makeRun(stage: "A1"))
        await companion.controlHandled(owner: owner(1), requestID: request.id, result: .applied, publication: Self.publication())
        #expect(try link.writtenStates().last?.run == makeRun(stage: "A2"))
        #expect(reply.answers.value.count == 1)
    }

    /// Two commands wait together: each reply goes back to its own request, whatever order the timer answers in.
    @Test
    func test_twoCommands_eachAnswerReachesItsOwnRequest() async throws {
        var (companion, requests) = await running()
        let first = Task { try await command(1) }
        let firstRequest = try #require(await requests.next())
        let second = Task { try await command(2, .resume, generation: 4) }
        let secondRequest = try #require(await requests.next())

        await companion.controlHandled(owner: owner(1), requestID: secondRequest.id, result: .stale, publication: Self.publication())
        await companion.controlHandled(owner: owner(1), requestID: firstRequest.id, result: .busy, publication: Self.publication())

        let secondReply = try await second.value
        let firstReply = try await first.value
        #expect(secondReply.requestID == UUID(link: 2))
        #expect(secondReply.result == .stale)
        #expect(firstReply.requestID == UUID(link: 1))
        #expect(firstReply.result == .busy)
    }

    @Test
    func test_commandAndRefresh_eachAnswerReachesItsOwnRequest() async throws {
        var (companion, requests) = await running()
        let refreshData = try WireCoding.encode(WatchRequestEnvelope(requestID: UUID(link: 1), request: .refresh(knownCatalogDigest: nil)))
        let refreshAnswer = LockIsolated<Data?>(nil)
        let refreshed = Observed(false)
        link.events.value?.yield(.request(refreshData, ReplyTicket { data in
            refreshAnswer.setValue(data)
            refreshed.setValue(true)
        }))
        let refreshRequest = try #require(await requests.next())
        let pending = Task { try await command(2) }
        let commandRequest = try #require(await requests.next())
        // Refreshes and commands take their numbers from one counter, so the timer never sees one twice.
        #expect(commandRequest.id == refreshRequest.id + 1)

        await companion.controlHandled(owner: owner(1), requestID: commandRequest.id, result: .busy, publication: Self.publication())
        await companion.refreshHandled(owner: owner(1), requestID: refreshRequest.id, publication: Self.publication(3, stage: "A3"))

        let reply = try await pending.value
        #expect(reply.requestID == UUID(link: 2))
        #expect(reply.result == .busy)
        await refreshed.wait { $0 }
        let refreshEnvelope = try WireCoding.decode(WatchReplyEnvelope.self, from: try #require(refreshAnswer.value))
        #expect(refreshEnvelope.requestID == UUID(link: 1))
        guard case let .state(state) = refreshEnvelope.reply else {
            Issue.record("A refresh got a command's reply")
            return
        }
        #expect(state.run == makeRun(stage: "A3"))
    }
}

/// The command tickets under the gate termination closes.
@Suite
struct CommandGateTests {
    private static func request(_ id: Int) -> WatchControlRequest {
        WatchControlRequest(id: id, kind: .command(.pause, generation: 1))
    }

    private static func admitted(
        _ gate: CommandGate,
        _ id: Int,
        owner ticketOwner: UUID,
        subscription: Int,
        into continuation: AsyncStream<WatchControlRequest>.Continuation
    ) throws -> OneAnswer<CommandAnswer?> {
        let admission = gate.admit(request(id), owner: ticketOwner, subscriptionID: subscription, into: continuation)
        guard case let .admitted(answer) = admission else {
            throw NotAdmitted()
        }
        return answer
    }

    private struct NotAdmitted: Error {}

    @Test
    func test_endSubscription_answersOnlyThatSubscriptionsTicketsTimedOut() async throws {
        let gate = CommandGate()
        // The stream is kept, so its continuation still takes commands.
        let (stream, continuation) = AsyncStream.makeStream(of: WatchControlRequest.self)
        defer { withExtendedLifetime(stream) {} }
        let ended = try Self.admitted(gate, 1, owner: owner(1), subscription: 1, into: continuation)
        let otherSubscription = try Self.admitted(gate, 2, owner: owner(1), subscription: 2, into: continuation)
        let otherOwner = try Self.admitted(gate, 3, owner: owner(2), subscription: 1, into: continuation)

        gate.endSubscription(owner: owner(1), subscriptionID: 1)

        #expect(await ended.wait(timeout: .zero, clock: ManualClock(), otherwise: nil)?.result == .timedOut)
        #expect(gate.answer(requestID: 2, owner: owner(1), CommandAnswer(result: .applied, publication: nil)))
        #expect(gate.answer(requestID: 3, owner: owner(2), CommandAnswer(result: .stale, publication: nil)))
        #expect(await otherSubscription.wait(timeout: .zero, clock: ManualClock(), otherwise: nil)?.result == .applied)
        #expect(await otherOwner.wait(timeout: .zero, clock: ManualClock(), otherwise: nil)?.result == .stale)
    }

    @Test
    func test_answer_anotherOwner_neitherTakesTheTicketNorWakesItsWait() async throws {
        let gate = CommandGate()
        // The stream is kept, so its continuation still takes commands.
        let (stream, continuation) = AsyncStream.makeStream(of: WatchControlRequest.self)
        defer { withExtendedLifetime(stream) {} }
        let answer = try Self.admitted(gate, 1, owner: owner(1), subscription: 1, into: continuation)

        #expect(!gate.answer(requestID: 1, owner: owner(2), CommandAnswer(result: .applied, publication: nil)))

        #expect(gate.answer(requestID: 1, owner: owner(1), CommandAnswer(result: .stale, publication: nil)))
        #expect(await answer.wait(timeout: .zero, clock: ManualClock(), otherwise: nil)?.result == .stale)
    }

    @Test
    func test_admit_afterClose_handsNothingOver() async {
        let gate = CommandGate()
        let (stream, continuation) = AsyncStream.makeStream(of: WatchControlRequest.self)
        gate.close()

        guard case .closed = gate.admit(Self.request(1), owner: owner(1), subscriptionID: 1, into: continuation) else {
            Issue.record("A closed gate admitted a command")
            return
        }
        continuation.finish()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

/// The budget covers every reply that can carry a state, including Start admission.
@Suite
struct PublicationLedgerBudgetTests {
    @Test
    func test_fits_matchesMaximumOfEveryControlAndStartReply() throws {
        let catalog: CatalogState = .loaded(makeCatalog(40))
        let probe = PhoneState(
            processID: UUID(link: 1),
            sequence: .max,
            publishedAt: linkNow,
            catalog: catalog,
            catalogDigest: String(repeating: "0", count: 64),
            run: makeRun(),
            isRunLive: true
        )
        let refreshSize = try WireCoding.encode(WatchReplyEnvelope(requestID: UUID(link: 1), reply: .state(probe))).count
        let commandSize = try WireCoding.encode(
            WatchReplyEnvelope(requestID: UUID(link: 1), reply: .control(.unavailable, probe))
        ).count
        let startSize = try WireCoding.encode(
            WatchReplyEnvelope(requestID: UUID(link: 1), reply: .start(.accepted(asksOnPhone: false), probe))
        ).count
        #expect(refreshSize < commandSize)
        #expect(commandSize < startSize)

        let fits = { (limit: Int) in
            PublicationLedger.fits(catalog: catalog, run: makeRun(), processID: UUID(link: 1), at: linkNow, limit: limit)
        }
        let fitsRefresh = fits(refreshSize)
        let fitsCommand = fits(commandSize)
        let fitsStart = fits(startSize)

        #expect(!fitsRefresh)
        #expect(!fitsCommand)
        #expect(fitsStart)

        let startResults: [WatchStartResult] = [
            .accepted(asksOnPhone: false), .accepted(asksOnPhone: true), .openPhoneApp, .busy,
            .listUnavailable, .changed, .gone, .notPlayable,
        ]
        let replies = startResults.map { WatchReply.start($0, probe) }
            + WatchControlResult.allCases.map { WatchReply.control($0, probe) }
        let sizes = try replies.map {
            try WireCoding.encode(WatchReplyEnvelope(requestID: UUID(link: 1), reply: $0)).count
        }
        let maximum = try #require(sizes.max())
        #expect(!fits(maximum - 1))
        #expect(fits(maximum))
    }
}
