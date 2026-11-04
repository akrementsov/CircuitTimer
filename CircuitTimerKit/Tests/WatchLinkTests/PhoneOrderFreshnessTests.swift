@testable import WatchLink

import Testing

@Suite
struct PhoneOrderFreshnessTests {
    @Test
    func test_newDigest_withoutCatalog_disablesStartUntilCatalogIsConfirmed() {
        var order = PhoneOrder()
        #expect(!order.vouchesForCatalog)
        _ = order.receive(makeState(sequence: 1, catalog: .loaded(makeCatalog(1)), digest: "A"), from: .context)
        #expect(order.vouchesForCatalog)

        _ = order.receive(makeState(sequence: 2, digest: "B"), from: .message)
        #expect(order.hasNewerCatalogDigest)
        #expect(!order.vouchesForCatalog)
        _ = order.receive(makeState(sequence: 1, digest: "A"), from: .reply)
        #expect(!order.vouchesForCatalog)
        _ = order.receive(makeState(sequence: 3, catalog: .loaded(makeCatalog(2)), digest: "B"), from: .reply)
        #expect(!order.hasNewerCatalogDigest)
        #expect(order.vouchesForCatalog)
    }
}
