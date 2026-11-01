@testable import WatchLink

import Foundation
import Testing

@Suite
struct PhoneOrderTests {
    private let catalog = CatalogState.loaded(makeCatalog(1))

    @Test(arguments: [StateSource.context, .message, .reply])
    func test_receive_unknownProcess_acceptsFromAnySource(source: StateSource) {
        var order = PhoneOrder()

        let outcome = order.receive(makeState(sequence: 4, catalog: catalog, digest: "A"), from: source)

        #expect(outcome == PhoneOrder.Outcome(change: .replaced(catalog), asksAgain: false))
        #expect(order.processID == UUID(link: 1))
        #expect(order.lastSequence == 4)
        #expect(order.catalogDigest == "A")
        #expect(order.catalogConfirmedBy == UUID(link: 1))
    }

    @Test
    func test_receive_sameProcess_needsANewerSequenceUnlessReplying() {
        var order = PhoneOrder()
        _ = order.receive(makeState(sequence: 4, catalog: catalog, digest: "A"), from: .context)

        #expect(order.receive(makeState(sequence: 4, catalog: catalog, digest: "B"), from: .context).change == nil)
        #expect(order.receive(makeState(sequence: 3, catalog: catalog, digest: "B"), from: .message).change == nil)
        #expect(order.receive(makeState(sequence: 3, catalog: catalog, digest: "B"), from: .reply).change == nil)
        #expect(order.receive(makeState(sequence: 4, digest: "A"), from: .reply).change == .confirmed)
        #expect(order.receive(makeState(sequence: 5, catalog: catalog, digest: "C"), from: .message).change == .replaced(catalog))
        #expect(order.lastSequence == 5)
    }

    @Test
    func test_receive_foreignProcess_isBelievedOnlyThroughAReply() {
        var order = PhoneOrder()
        _ = order.receive(makeState(process: 1, sequence: 9, catalog: catalog, digest: "A"), from: .context)

        let unasked = order.receive(makeState(process: 2, sequence: 1, catalog: catalog, digest: "B"), from: .context)
        #expect(unasked == PhoneOrder.Outcome(change: nil, asksAgain: true))
        #expect(order.processID == UUID(link: 1))

        let reply = order.receive(makeState(process: 2, sequence: 1, catalog: catalog, digest: "B"), from: .reply)
        #expect(reply.change == .replaced(catalog))
        #expect(order.processID == UUID(link: 2))
        #expect(order.lastSequence == 1)
    }

    @Test
    func test_receive_noCatalog_unknownConfirmedOrAskedOnce() {
        var order = PhoneOrder()
        _ = order.receive(makeState(sequence: 1, catalog: catalog, digest: "A"), from: .context)

        let unknown = order.receive(makeState(process: 2, sequence: 0), from: .reply)
        #expect(unknown == PhoneOrder.Outcome(change: .unknown, asksAgain: false))
        #expect(order.catalogDigest == "A")
        #expect(order.catalogConfirmedBy == UUID(link: 1))

        let confirmed = order.receive(makeState(process: 2, sequence: 1, digest: "A"), from: .message)
        #expect(confirmed == PhoneOrder.Outcome(change: .confirmed, asksAgain: false))
        #expect(order.catalogConfirmedBy == UUID(link: 2))

        #expect(order.receive(makeState(process: 2, sequence: 2, digest: "B"), from: .message).asksAgain)
        #expect(!order.receive(makeState(process: 2, sequence: 2, digest: "B"), from: .reply).asksAgain)
    }

    @Test
    func test_receive_ninthAskedState_forgetsTheFirst() {
        var order = PhoneOrder()
        _ = order.receive(makeState(process: 1, sequence: 1, catalog: catalog, digest: "A"), from: .context)
        for sequence in 1...8 {
            #expect(order.receive(makeState(process: 2, sequence: sequence), from: .context).asksAgain)
        }

        #expect(!order.receive(makeState(process: 2, sequence: 8), from: .context).asksAgain)
        #expect(order.receive(makeState(process: 3, sequence: 1), from: .context).asksAgain)
        #expect(order.receive(makeState(process: 2, sequence: 1), from: .context).asksAgain)
    }
}
