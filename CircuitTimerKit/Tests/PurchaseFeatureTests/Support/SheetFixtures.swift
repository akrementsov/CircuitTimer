@testable import PurchaseFeature

import ComposableArchitecture
import Purchases

let price = FullVersionOffer(displayPrice: "$0.99")

/// A sheet that has appeared and shows the price, with `status` and `operation` as given.
func sheet(
    _ entry: PurchaseFeature.Entry = .browse,
    status: FullVersionStatus = .free,
    operation: PurchaseFeature.Operation? = nil
) -> PurchaseFeature.State {
    var state = PurchaseFeature.State(entry: entry)
    state.hasStarted = true
    state.offer = .loaded(price)
    state.status = status
    state.operation = operation
    return state
}

/// Every endpoint a test leaves alone keeps its unimplemented test value, so a call it did not expect fails it.
@MainActor
func makeStore(
    _ state: PurchaseFeature.State,
    dependencies: (inout DependencyValues) -> Void = { _ in }
) -> TestStoreOf<PurchaseFeature> {
    TestStore(initialState: state) {
        PurchaseFeature()
    } withDependencies: {
        $0.continuousClock = TestClock<Duration>()
        dependencies(&$0)
    }
}

/// Holds a stubbed call in flight until the test opens it.
struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        for await _ in stream {}
    }

    func open() {
        continuation.finish()
    }
}

struct StoreFailure: Error {}
