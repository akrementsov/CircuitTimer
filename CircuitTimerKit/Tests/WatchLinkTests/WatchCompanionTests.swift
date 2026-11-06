@testable import WatchLink

import Dependencies
import Foundation
import Testing

@Suite
struct WatchCompanionTests {
    private let link = FakeLink()

    /// Starts the actor on the fake's events, as the live client does.
    private func start() async -> WatchCompanion {
        let companion = await WatchCompanion.make(link: link, clock: TestClock())
        let events = link.transport.events()
        Task { await companion.run(events) }
        return companion
    }

    /// Sends a request to the actor and waits for its one answer.
    private func ask(_ data: Data) async -> (reply: Data, count: Int) {
        let answers = LockIsolated<[Data]>([])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ticket = ReplyTicket { data in
                answers.withValue { $0.append(data) }
                continuation.resume()
            }
            link.events.value?.yield(.request(data, ticket))
        }
        return (answers.value[0], answers.value.count)
    }

    @Test
    func test_request_refresh_isAnsweredOnceWithItsID() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))
        let request = try WireCoding.encode(WatchRequestEnvelope(requestID: UUID(link: 7), request: .refresh(knownCatalogDigest: nil)))

        let (data, count) = await ask(request)

        let reply = try WireCoding.decode(WatchReplyEnvelope.self, from: data)
        #expect(count == 1)
        #expect(reply.requestID == UUID(link: 7))
        guard case let .state(state) = reply.reply else {
            Issue.record("No state in the reply")
            return
        }
        #expect(state.catalog == .loaded(makeCatalog(1)))
    }

    @Test(arguments: [
        Data("garbage".utf8),
        Data(#"{"schemaVersion":2,"requestID":"00000000-0000-0000-0000-000000000000"}"#.utf8),
        Data(#"{"schemaVersion":1,"request":"nonsense"}"#.utf8),
    ])
    func test_request_unreadable_isAnsweredUnreadable(request: Data) async throws {
        _ = await start()

        let (data, count) = await ask(request)

        #expect(count == 1)
        #expect(try WireCoding.decode(WatchReplyEnvelope.self, from: data) == .unreadable)
    }

    @Test
    func test_publishCatalog_pushesWhatItPublishedToAReachableWatch() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))
        #expect(try link.sentStates() == link.writtenStates())

        link.snapshot.withValue { $0.canPublish = false }
        await companion.publishCatalog(revision: 2, catalog: .loaded(makeCatalog(2)))
        #expect(try link.sentStates().map(\.catalog) == [.loaded(makeCatalog(1)), .loaded(makeCatalog(2))])
        #expect(link.contexts.value.count == 1)

        link.snapshot.withValue {
            $0.canPublish = true
            $0.isReachable = false
        }
        await companion.publishCatalog(revision: 3, catalog: .loaded(makeCatalog(3)))
        link.snapshot.withValue { $0.isReachable = true }
        await companion.publishCatalog(revision: 4, catalog: .loaded(makeCatalog(3)))
        #expect(link.messages.value.count == 2)
    }

    /// A context write refused as too large on activation falls back, and an open watch gets the fallback at once.
    @Test
    func test_activation_refusedWrite_pushesTheFallback() async throws {
        let companion = await start()
        link.snapshot.withValue { $0.canPublish = false }
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(4)))
        link.snapshot.withValue { $0.canPublish = true }
        link.refusals.setValue([FakeLink.tooLarge])
        let events = try #require(link.events.value)

        events.yield(.activated)
        // The write runs on the ledger's queue, and its fallback reaches the watch from there.
        await link.messages.wait { $0.count == 2 }

        #expect(try link.sentStates().map(\.catalog) == [.loaded(makeCatalog(4)), .loaded(makeCatalog(4).prefix(2))])
        #expect(try link.sentStates().last == link.writtenStates().last)
    }

    @Test
    func test_watchChanged_thenActivation_writesTheNewestStateAgain() async throws {
        let companion = await start()
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(1)))
        let events = try #require(link.events.value)

        events.yield(.activated)
        events.yield(.watchChanged)
        events.yield(.activated)
        // The writes enter the ledger's queue in the order of the events: the first activation finds the state
        // written, the change of watch forgets that, the second activation writes it again.
        await link.contexts.wait { $0.count == 2 }

        #expect(try link.writtenStates()[1] == link.writtenStates()[0])
    }
}
