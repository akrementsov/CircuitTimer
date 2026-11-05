@testable import WatchLink

import Dependencies
import Foundation
import Testing
import TestSupport

/// The full version gate in the companion: what an open watch is sent when the access changes, and the requests it
/// refuses before they reach a timer or the app.
@Suite(.timeLimit(.minutes(1)))
struct WatchCompanionAccessTests {
    private let link = FakeLink()
    private let clock = ManualClock()

    private static let four: CatalogState = .loaded(makeCatalog(4))

    /// Starts the actor on the fake's events, as the live client does, on `ledger` when the test reads it too.
    private func start(access: WatchAccess? = .granted, ledger: PublicationLedger? = nil) async -> WatchCompanion {
        let companionLedger: PublicationLedger
        if let ledger {
            companionLedger = ledger
        } else {
            companionLedger = await PublicationLedger.make(link: link, access: access)
        }
        let companion = WatchCompanion(ledger: companionLedger, now: { linkNow }, clock: clock)
        let events = link.transport.events()
        Task { await companion.run(events) }
        return companion
    }

    private struct UnexpectedReply: Error {}

    /// Sends a request of the watch and returns its first reply.
    private func ask(_ request: WatchRequest, _ number: Int) async throws -> WatchReply {
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
        guard let reply = try WireCoding.decode(WatchReplyEnvelope.self, from: answers.value[0]).reply else {
            throw UnexpectedReply()
        }
        return reply
    }

    private func refresh(_ number: Int) async throws -> PhoneState {
        guard case let .state(state) = try await ask(.refresh(knownCatalogDigest: nil), number) else { throw UnexpectedReply() }
        return state
    }

    private func command(_ number: Int) async throws -> (WatchControlResult, PhoneState) {
        let request = WatchRequest.control(owner: owner(1), command: .pause, generation: 3, knownCatalogDigest: nil)
        guard case let .control(result, state) = try await ask(request, number) else { throw UnexpectedReply() }
        return (result, state)
    }

    private func startWorkout(_ number: Int) async throws -> (WatchStartResult, PhoneState) {
        let request = WatchRequest.start(workoutID: UUID(link: 1), scheduleFingerprint: "schedule", knownCatalogDigest: nil)
        guard case let .start(result, state) = try await ask(request, number) else { throw UnexpectedReply() }
        return (result, state)
    }

    @Test
    func test_publishAccess_locked_sendsAnOpenWatchTheLockWithItsCatalog() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: Self.four)
        await companion.publishRun(revision: 1, run: makeRun())

        await companion.publishAccess(revision: 2, access: .locked)

        let lock = try #require(try link.writtenStates().last)
        #expect(lock.catalog == .unavailable(.locked))
        #expect(try link.sentStates().last == lock)
        companion.closeGate()
    }

    /// Termination sends its state without the catalog, but a lock it numbers travels whole: a watch that has no lock
    /// yet would otherwise keep its list.
    @Test
    func test_finishTermination_lockItNumbers_isSentWithItsCatalog() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: Self.four)
        link.snapshot.withValue { $0.canPublish = false }
        await companion.publishAccess(revision: 2, access: .locked)
        link.snapshot.withValue { $0.canPublish = true }
        companion.closeGate()

        await companion.finishTermination()

        let lock = try #require(try link.writtenStates().last)
        #expect(lock.catalog == .unavailable(.locked))
        let sent = try link.sentStates()
        #expect(sent.last == lock)
        // The pending lock went out whole too, before termination numbered it again.
        #expect(sent.dropFirst().map(\.catalog) == [.unavailable(.locked), .unavailable(.locked)])
    }

    @Test
    func test_publishRunAndEnd_granted_stillSendTheStateWithoutTheCatalog() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: Self.four)
        let digest = try WatchCatalog.digest(of: Self.four)

        await companion.publishRun(revision: 1, run: makeRun())
        let withRun = try #require(try link.sentStates().last)
        await companion.end(owner: owner(1))
        let ended = try #require(try link.sentStates().last)

        #expect(withRun.run == makeRun())
        #expect(withRun.catalog == nil)
        #expect(withRun.catalogDigest == digest)
        #expect(ended.run == nil)
        #expect(ended.catalog == nil)
        #expect(ended.catalogDigest == digest)
        companion.closeGate()
    }

    /// The lock refused as too large went out at once; an activation writes it as it is once it fits, without a
    /// message, or numbers it anew and sends that while it is still refused.
    @Test(arguments: [false, true])
    func test_activation_afterARefusedLockWasSent_writesItOrSendsItNumberedAnew(refusedAgain: Bool) async throws {
        let ledger = await PublicationLedger.make(link: link)
        let companion = await start(ledger: ledger)
        await companion.publishCatalog(revision: 1, catalog: Self.four)
        link.refusals.setValue([FakeLink.tooLarge])
        await companion.publishAccess(revision: 2, access: .locked)
        let lock = try #require(try link.sentStates().last)
        #expect(lock.catalog == .unavailable(.locked))
        #expect(link.contexts.value.count == 1)
        let events = try #require(link.events.value)

        if refusedAgain {
            link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge])
            events.yield(.activated)
            await link.messages.wait { $0.count == 3 }
            let renumbered = try #require(try link.sentStates().last)
            #expect(renumbered.sequence == lock.sequence + 1)
            #expect(renumbered.catalog == .unavailable(.locked))
            #expect(link.contexts.value.count == 1)
        } else {
            events.yield(.activated)
            await link.contexts.wait { $0.count == 2 }
            await ledger.settle()
            #expect(try link.writtenStates().last == lock)
            #expect(link.messages.value.count == 2)
        }
        companion.closeGate()
    }

    /// Undecided or locked, every request is answered at once with the state the watch should show, and none reaches
    /// the timer or the app: after a purchase the first command and Start they get are the new ones.
    @Test(arguments: [nil, WatchAccess.locked] as [WatchAccess?])
    func test_requests_withoutAccess_areRefusedBeforeTheTimerAndTheApp(access: WatchAccess?) async throws {
        let companion = await start(access: access)
        await companion.publishCatalog(revision: 1, catalog: Self.four)
        await companion.publishRun(revision: 1, run: makeRun())
        var requests = await companion.controlRequests(owner: owner(1)).makeAsyncIterator()
        var starts = await companion.startRequests().makeAsyncIterator()

        let refreshed = try await refresh(7)
        let (commandResult, commanded) = try await command(8)
        let (startResult, started) = try await startWorkout(9)

        #expect(commandResult == .unavailable)
        #expect(startResult == (access == .locked ? .listUnavailable : .openPhoneApp))
        for state in [refreshed, commanded, started] {
            #expect(state.run == nil)
            #expect(!state.isRunLive)
            if access == .locked {
                #expect(state.catalog == .unavailable(.locked))
                #expect(state.catalogDigest == (try lockedDigest()))
            } else {
                #expect(state.sequence == 0)
                #expect(state.catalog == nil)
            }
        }

        await companion.publishAccess(revision: 2, access: .granted)
        let pendingCommand = Task { try await command(10) }
        let request = try #require(await requests.next())
        #expect(request.kind == .command(.pause, generation: 3))
        await companion.controlHandled(
            owner: owner(1),
            requestID: request.id,
            result: .applied,
            publication: WatchRunPublication(revision: 2, run: makeRun(stage: "A2"))
        )
        #expect(try await pendingCommand.value.0 == .applied)
        let pendingStart = Task { try await startWorkout(11) }
        let startRequest = try #require(await starts.next())
        #expect(await companion.startHandled(requestID: startRequest.id, result: .accepted(asksOnPhone: false)))
        #expect(try await pendingStart.value.0 == .accepted(asksOnPhone: false))
        companion.closeGate()
    }
}
