@testable import WatchLink

import Dependencies
import Foundation
import Testing

@Suite
struct PublicationLedgerTests {
    private let link = FakeLink()
    private var ledger: PublicationLedger {
        PublicationLedger(processID: UUID(link: 1), transport: link.transport)
    }

    @Test
    func test_publish_twoCatalogs_numbersThemInTheOrderOfTheirWrites() async throws {
        let ledger = ledger
        let first = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        let second = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(2)), at: linkNow)

        let written = try link.writtenStates()
        #expect(written.map(\.sequence) == [1, 2])
        #expect(first == .written(written[0]))
        #expect(second == .written(written[1]))
        #expect(written[1].catalog == .loaded(makeCatalog(2)))
        #expect(written[1].catalogDigest == (try WatchCatalog.digest(of: .loaded(makeCatalog(2)))))
    }

    @Test
    func test_reply_nothingPublishedSameOrOtherDigest_answersUnknownConfirmationOrState() async throws {
        let ledger = ledger
        let unknown = await ledger.reply(knownCatalogDigest: "X", at: linkNow)
        #expect(unknown.sequence == 0)
        #expect(unknown.catalog == nil)
        #expect(unknown.catalogDigest == nil)

        let published = Date(timeIntervalSinceReferenceDate: 700_000_000)
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: published)
        let digest = try WatchCatalog.digest(of: .loaded(makeCatalog(1)))

        let confirmation = await ledger.reply(knownCatalogDigest: digest, at: linkNow)
        #expect(confirmation.catalog == nil)
        #expect(confirmation.catalogDigest == digest)
        #expect(confirmation.sequence == 1)
        #expect(confirmation.publishedAt == linkNow)

        let full = await ledger.reply(knownCatalogDigest: "old", at: linkNow)
        #expect(full.catalog == .loaded(makeCatalog(1)))
        #expect(full.sequence == 1)
        // The iPhone answers for the list now, not when it published it.
        #expect(full.publishedAt == linkNow)
    }

    @Test
    func test_publish_catalogs_cutToTheEnvelopeLimit() async throws {
        let ledger = ledger
        let large = makeCatalog(200) { "Workout \($0) " + String(repeating: "x", count: 400) }
        _ = await ledger.publish(revision: 1, catalog: .loaded(large), at: linkNow)
        let huge = makeCatalog(1) { _ in String(repeating: "y", count: 70_000) }
        _ = await ledger.publish(revision: 2, catalog: .loaded(huge), at: linkNow)
        _ = await ledger.publish(revision: 3, catalog: .loaded(makeCatalog(0)), at: linkNow)

        let written = try link.writtenStates()
        guard case let .loaded(cut) = written[0].catalog else {
            Issue.record("The large catalog was not published as a list")
            return
        }
        #expect(cut.isTruncated)
        #expect(cut.entries.count < 200)
        #expect(cut.entries == Array(large.entries.prefix(cut.entries.count)))
        // The cut is the largest prefix whose longest reply fits: one more workout would not.
        #expect(try Self.longestReplySize(of: cut) <= WatchLinkSchema.envelopeLimit)
        #expect(try Self.longestReplySize(of: large.prefix(cut.entries.count + 1)) > WatchLinkSchema.envelopeLimit)
        #expect(written[1].catalog == .unavailable(.tooLarge))
        #expect(written[2].catalog == .loaded(WatchCatalog(entries: [])))
    }

    @Test
    func test_publish_failedOrImpossibleWrite_isPendingUntilWriteLatest() async throws {
        let ledger = ledger
        link.refusals.setValue([FakeLink.unreachable])
        let failed = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        guard case let .pending(state) = failed else {
            Issue.record("A failed write was not pending: \(failed)")
            return
        }
        #expect(link.contexts.value.isEmpty)

        #expect(await ledger.writeLatest() == nil)
        #expect(try link.writtenStates() == [state])
        #expect(await ledger.writeLatest() == nil)
        #expect(link.contexts.value.count == 1)

        link.snapshot.withValue { $0.canPublish = false }
        let impossible = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(2)), at: linkNow)
        let digest = try WatchCatalog.digest(of: .loaded(makeCatalog(2)))
        #expect(impossible == .pending(makeState(sequence: 2, catalog: .loaded(makeCatalog(2)), digest: digest, publishedAt: linkNow)))
        #expect(link.contexts.value.count == 1)
    }

    @Test
    func test_publish_refusedAsTooLarge_fallsBackToHalfThenUnavailable() async throws {
        let ledger = ledger
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(4)), at: linkNow)
        #expect(try link.writtenStates().last?.catalog == .loaded(makeCatalog(4).prefix(2)))

        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge])
        _ = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(6)), at: linkNow)
        #expect(try link.writtenStates().last?.catalog == .unavailable(.tooLarge))

        // A list in between, so the single workout's fallback is not the state already written.
        _ = await ledger.publish(revision: 3, catalog: .loaded(makeCatalog(2)), at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publish(revision: 4, catalog: .loaded(makeCatalog(1) { _ in "Only" }), at: linkNow)
        #expect(try link.writtenStates().last?.catalog == .unavailable(.tooLarge))
        // Every refused candidate took a number of its own.
        #expect(try link.writtenStates().map(\.sequence) == [2, 5, 6, 8])
    }

    @Test
    func test_publish_everyCandidateRefused_skipsAndKeepsThePreviousState() async throws {
        let ledger = ledger
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])

        let outcome = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(4)), at: linkNow)

        #expect(outcome == .skipped)
        #expect(link.contexts.value.count == 1)
        let reply = await ledger.reply(knownCatalogDigest: nil, at: linkNow)
        #expect(reply.catalog == .loaded(makeCatalog(1)))
    }

    @Test
    func test_writeLatest_refusedAsTooLarge_fallsBackLikeAPublication() async throws {
        let ledger = ledger
        link.snapshot.withValue { $0.canPublish = false }
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(4)), at: linkNow)
        link.snapshot.withValue { $0.canPublish = true }
        link.refusals.setValue([FakeLink.tooLarge])

        let fallback = await ledger.writeLatest()

        #expect(try link.writtenStates().map(\.catalog) == [.loaded(makeCatalog(4).prefix(2))])
        #expect(try fallback == link.writtenStates().last)
    }

    @Test
    func test_publish_sameDigest_skipsOnlyAfterASuccessfulWrite() async throws {
        let ledger = ledger
        link.refusals.setValue([FakeLink.unreachable])
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        let retried = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(1)), at: linkNow)
        let skipped = await ledger.publish(revision: 3, catalog: .loaded(makeCatalog(1)), at: linkNow)

        #expect(link.contexts.value.count == 1)
        guard case .written = retried else {
            Issue.record("An unwritten catalog was not written again: \(retried)")
            return
        }
        #expect(skipped == .skipped)
    }

    @Test
    func test_watchChanged_writesTheNewestStateAgain() async throws {
        let ledger = ledger
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        _ = await ledger.writeLatest()
        #expect(link.contexts.value.count == 1)

        await ledger.watchChanged()
        _ = await ledger.writeLatest()

        let written = try link.writtenStates()
        #expect(written.count == 2)
        #expect(written[1] == written[0])
    }

    @Test
    func test_publish_olderRevision_isSkipped() async throws {
        let ledger = ledger
        _ = await ledger.publish(revision: 3, catalog: .loaded(makeCatalog(3)), at: linkNow)
        let older = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(2)), at: linkNow)

        #expect(older == .skipped)
        #expect(try link.writtenStates().map(\.catalog) == [.loaded(makeCatalog(3))])

        // An older revision is dropped before it tries a write, so a refusal never takes it down the fallback path.
        link.refusals.setValue([FakeLink.tooLarge])
        let olderOnTheFallbackPath = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(4)), at: linkNow)
        #expect(olderOnTheFallbackPath == .skipped)
        #expect(link.refusals.value.count == 1)
        #expect(link.contexts.value.count == 1)
    }

    @Test
    func test_publish_olderRevisionAfterARefusedOne_keepsTheFallbackWritten() async throws {
        let ledger = ledger
        link.refusals.setValue([FakeLink.tooLarge])
        let refused = await ledger.publish(revision: 3, catalog: .loaded(makeCatalog(4)), at: linkNow)
        let older = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(6)), at: linkNow)

        guard case let .written(half) = refused else {
            Issue.record("The refused list fell back to nothing: \(refused)")
            return
        }
        #expect(half.catalog == .loaded(makeCatalog(4).prefix(2)))
        #expect(older == .skipped)
        #expect(try link.writtenStates() == [half])
        let reply = await ledger.reply(knownCatalogDigest: nil, at: linkNow)
        #expect(reply.catalog == half.catalog)
    }

    @Test
    func test_publish_concurrentRevisions_writeIncreasingSequencesOfIncreasingRevisions() async throws {
        let ledger = ledger
        await withTaskGroup(of: Void.self) { group in
            for revision in 1...40 {
                group.addTask {
                    _ = await ledger.publish(revision: revision, catalog: .loaded(makeCatalog(revision)), at: linkNow)
                }
            }
        }

        let written = try link.writtenStates()
        let counts = written.map { state -> Int in
            guard case let .loaded(catalog) = state.catalog else { return -1 }
            return catalog.entries.count
        }
        #expect(!written.isEmpty)
        #expect(written.map(\.sequence) == written.map(\.sequence).sorted())
        #expect(Set(written.map(\.sequence)).count == written.count)
        #expect(counts == counts.sorted())
        #expect(Set(counts).count == counts.count)
    }

    /// The size of a reply carrying `catalog` with the largest number and a full digest, the longest way it travels.
    private static func longestReplySize(of catalog: WatchCatalog) throws -> Int {
        let state = PhoneState(
            processID: UUID(link: 1),
            sequence: .max,
            publishedAt: linkNow,
            catalog: .loaded(catalog),
            catalogDigest: String(repeating: "0", count: 64)
        )
        return try WireCoding.encode(WatchReplyEnvelope(requestID: UUID(link: 1), reply: .state(state))).count
    }
}
