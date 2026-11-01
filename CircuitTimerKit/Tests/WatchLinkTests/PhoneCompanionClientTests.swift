@testable import WatchLink

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PhoneCompanionClientTests {
    private let watch = FakeLink()

    @Test
    func test_phoneEvents_sessionEvents_mapToLinkEvents() async throws {
        let stream = PhoneCompanionClient.phoneEvents(from: watch.transport)
        let source = try #require(watch.events.value)
        let state = makeState(sequence: 1, catalog: .loaded(makeCatalog(1)), digest: "A")
        let answer = LockIsolated<Data?>(nil)

        source.yield(.activated)
        source.yield(.context(try WireCoding.encode(state)))
        source.yield(.message(try WireCoding.encode(state)))
        source.yield(.context(Data(#"{"schemaVersion":2}"#.utf8)))
        source.yield(.message(Data("garbage".utf8)))
        source.yield(.request(Data(), ReplyTicket { answer.setValue($0) }))
        source.yield(.watchChanged)
        source.finish()

        var events: [PhoneLinkEvent] = []
        for await event in stream {
            events.append(event)
        }
        let status = watch.snapshot.value.linkStatus
        #expect(events == [
            .status(status),
            .context(state),
            .message(state),
            .undecodable(peerSchemaVersion: 2),
            .undecodable(peerSchemaVersion: nil),
            .status(status),
        ])
        #expect(answer.value == Data())
    }

    @Test
    func test_phoneEvents_readerStops_releasesTheSource() async throws {
        let stream = PhoneCompanionClient.phoneEvents(from: watch.transport)
        let reader = Task {
            for await _ in stream {}
        }
        reader.cancel()
        await reader.value

        // Returns once the source ends; if it never does, the suite's time limit fails the test.
        for await _ in watch.eventsEnded {}
    }

    @Test
    func test_send_failuresAndOtherVersions_throwLinkErrors() async throws {
        let envelope = WatchRequestEnvelope(requestID: UUID(link: 1), request: .refresh(knownCatalogDigest: nil))
        let cases: [(@Sendable (Data) async throws -> Data, PhoneLinkError)] = [
            ({ _ in throw FakeLink.unreachable }, .unreachable),
            ({ _ in Data(#"{"schemaVersion":2}"#.utf8) }, .incompatible(peerSchemaVersion: 2)),
            ({ _ in Data(#"{"schemaVersion":1,"reply":42}"#.utf8) }, .incompatible(peerSchemaVersion: 1)),
            ({ _ in Data("garbage".utf8) }, .incompatible(peerSchemaVersion: nil)),
        ]
        for (respond, expected) in cases {
            watch.respond.setValue(respond)
            await #expect(throws: expected) {
                try await PhoneCompanionClient.send(envelope, through: watch.transport)
            }
        }
    }

    @Test
    func test_replyTicket_secondReply_isIgnored() {
        let answers = LockIsolated<[Data]>([])
        let ticket = ReplyTicket { data in answers.withValue { $0.append(data) } }

        ticket.reply(Data("one".utf8))
        ticket.reply(Data("two".utf8))

        #expect(answers.value == [Data("one".utf8)])
    }

    /// The watch's client and the iPhone's actor read each other's bytes.
    @Test
    func test_send_toTheIPhoneActor_getsUnknownThenTheCatalog() async throws {
        let phone = FakeLink()
        let companion = WatchCompanion(
            ledger: PublicationLedger(processID: UUID(link: 5), transport: phone.transport),
            transport: phone.transport,
            now: { linkNow }
        )
        let events = phone.transport.events()
        Task { await companion.run(events) }
        watch.respond.setValue { data in
            await withCheckedContinuation { continuation in
                phone.events.value?.yield(.request(data, ReplyTicket { continuation.resume(returning: $0) }))
            }
        }
        let envelope = WatchRequestEnvelope(requestID: UUID(link: 2), request: .refresh(knownCatalogDigest: nil))

        let before = try await PhoneCompanionClient.send(envelope, through: watch.transport)
        await companion.publishCatalog(revision: 1, catalog: .loaded(makeCatalog(2)))
        let after = try await PhoneCompanionClient.send(envelope, through: watch.transport)

        #expect(before == WatchReplyEnvelope(
            requestID: UUID(link: 2),
            reply: .state(PhoneState(processID: UUID(link: 5), sequence: 0, publishedAt: linkNow, catalog: nil, catalogDigest: nil))
        ))
        guard case let .state(state) = after.reply else {
            Issue.record("No state after the publication")
            return
        }
        #expect(state.catalog == .loaded(makeCatalog(2)))
        #expect(state.publishedAt == linkNow)
    }
}
