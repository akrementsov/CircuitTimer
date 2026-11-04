@testable import WatchLink

import Foundation
import Testing

@Suite
struct StartWireBudgetTests {
    private let results: [WatchStartResult] = [
        .accepted(asksOnPhone: false), .accepted(asksOnPhone: true), .openPhoneApp,
        .busy, .listUnavailable, .changed, .gone, .notPlayable,
    ]

    private func probe(_ catalog: CatalogState, run: WatchRun? = nil) -> PhoneState {
        PhoneState(
            processID: UUID(link: 1),
            sequence: .max,
            publishedAt: linkNow,
            catalog: catalog,
            catalogDigest: String(repeating: "0", count: 64),
            run: run,
            isRunLive: run != nil
        )
    }

    private func size(_ reply: WatchReply) throws -> Int {
        try WireCoding.encode(WatchReplyEnvelope(requestID: UUID(link: 1), reply: reply)).count
    }

    @Test
    func test_publish_catalogFitsControlButNotStart_truncatesAndKeepsRunReserve() async throws {
        #expect(WatchLinkSchema.envelopeLimit == 60_000)
        #expect(WatchLinkSchema.runReserve == 8_192)
        let limit = 60_000 - 8_192
        let base = makeCatalog(2) { _ in "" }
        let controlSize = try #require(try WatchControlResult.allCases.map { try size(.control($0, probe(.loaded(base)))) }.max())
        let catalog = makeCatalog(2) { $0 == 0 ? "" : String(repeating: "x", count: limit - controlSize) }
        let state = probe(.loaded(catalog))
        #expect(try WatchControlResult.allCases.allSatisfy { try size(.control($0, state)) <= limit })
        #expect(try results.contains { try size(.start($0, state)) > limit })
        let link = FakeLink()
        let ledger = PublicationLedger(processID: UUID(link: 1), transport: link.transport)
        _ = await ledger.publish(revision: 1, catalog: .loaded(catalog), at: linkNow)
        let written = try #require(try link.writtenStates().last)
        guard case let .loaded(cut) = written.catalog else {
            Issue.record("A prefix that fits was replaced by an unavailable catalog")
            return
        }
        #expect(cut.entries == [catalog.entries[0]])
        #expect(cut.isTruncated)
        #expect(try results.allSatisfy { try size(.start($0, probe(.loaded(cut)))) <= limit })
    }

    @Test
    func test_startEnvelopes_allResults_roundTripWithCorrelation() throws {
        let request = WatchRequestEnvelope(
            requestID: UUID(link: 70),
            request: .start(workoutID: UUID(link: 5), scheduleFingerprint: "fingerprint", knownCatalogDigest: "digest")
        )
        #expect(try WireCoding.decode(WatchRequestEnvelope.self, from: WireCoding.encode(request)) == request)
        for result in results {
            let reply = WatchReplyEnvelope(requestID: UUID(link: 70), reply: .start(result, probe(.loaded(makeCatalog(1)))))
            #expect(try WireCoding.decode(WatchReplyEnvelope.self, from: WireCoding.encode(reply)) == reply)
        }
    }
}
