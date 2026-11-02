@testable import PurchaseFeature

import ComposableArchitecture
import Foundation
import Purchases
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PurchaseFeatureTests {
    // MARK: - Appearing and the price

    @Test(arguments: [PurchaseFeature.Entry.browse, .limit(.workoutLimit), .restore])
    func test_task_loadsThePriceFollowsTheStatusAndRestoresOnlyForRestore(entry: PurchaseFeature.Entry) async {
        let offer = Gate()
        let restore = Gate()
        let restores = LockIsolated(0)
        let statuses = AsyncStream<FullVersionStatus>.makeStream()
        let store = makeStore(PurchaseFeature.State(entry: entry)) {
            $0.purchases.offer = {
                await offer.wait()
                return price
            }
            $0.purchases.changes = { statuses.stream }
            if entry == .restore {
                $0.purchases.restore = {
                    restores.withValue { $0 += 1 }
                    await restore.wait()
                    return .cancelled
                }
            }
        }

        await store.send(.view(.task)) {
            $0.hasStarted = true
            if entry == .restore { $0.operation = .restoring }
        }
        await store.send(.view(.task))
        offer.open()
        await store.receive(.internal(.offerLoaded(price))) { $0.offer = .loaded(price) }
        if entry == .restore {
            restore.open()
            await store.receive(.internal(.restoreFinished(.cancelled))) { $0.operation = nil }
        }
        statuses.continuation.yield(.free)
        await store.receive(.internal(.statusChanged(.free))) { $0.status = .free }

        statuses.continuation.finish()
        await store.finish()
        #expect(restores.value == (entry == .restore ? 1 : 0))
    }

    @Test
    func test_retry_failedPrice_loadsItAgainAndIsIgnoredOnceLoaded() async {
        let fails = LockIsolated(true)
        let store = makeStore(PurchaseFeature.State(entry: .browse)) {
            $0.purchases.offer = {
                if fails.value { throw StoreFailure() }
                return price
            }
            $0.purchases.changes = { AsyncStream { $0.finish() } }
        }

        await store.send(.view(.task)) { $0.hasStarted = true }
        await store.receive(.internal(.offerFailed)) { $0.offer = .unavailable }
        fails.setValue(false)
        await store.send(.view(.retryTapped)) { $0.offer = .loading }
        await store.receive(.internal(.offerLoaded(price))) { $0.offer = .loaded(price) }
        await store.send(.view(.retryTapped))
    }

    @Test(arguments: ["offer", "purchase", "restore"])
    func test_cancellation_ofAnyCall_sendsNothingAndShowsNoAlert(call: String) async {
        let store: TestStoreOf<PurchaseFeature>
        switch call {
            case "offer":
                store = makeStore(PurchaseFeature.State(entry: .browse)) {
                    $0.purchases.offer = { throw CancellationError() }
                    $0.purchases.changes = { AsyncStream { $0.finish() } }
                }
                await store.send(.view(.task)) { $0.hasStarted = true }
            case "purchase":
                store = makeStore(sheet()) { $0.purchases.purchase = { throw CancellationError() } }
                await store.send(.view(.buyTapped)) { $0.operation = .purchasing }
            default:
                store = makeStore(sheet()) { $0.purchases.restore = { throw CancellationError() } }
                await store.send(.view(.restoreTapped)) { $0.operation = .restoring }
        }

        await store.finish()
        #expect(store.state.destination == nil)
    }

    // MARK: - Closing and taps

    @Test(arguments: [PurchaseFeature.Action.View.closeTapped, .doneTapped])
    func test_closeOrDone_asksToCloseOnlyWhenNotBusy(tap: PurchaseFeature.Action.View) async {
        for operation in [PurchaseFeature.Operation.purchasing, .restoring] {
            let busy = makeStore(sheet(operation: operation))
            await busy.send(.view(tap))
        }
        var awaiting = sheet()
        awaiting.isAwaitingConfirmation = true
        await makeStore(awaiting).send(.view(tap))

        let idle = makeStore(sheet())
        await idle.send(.view(tap))
        await idle.receive(.delegate(.closeRequested))
    }

    @Test
    func test_buy_quickRepeatedTaps_startOneOperation() async {
        let purchase = Gate()
        let purchases = LockIsolated(0)
        let store = makeStore(sheet()) {
            $0.purchases.purchase = {
                purchases.withValue { $0 += 1 }
                await purchase.wait()
                return .cancelled
            }
        }

        await store.send(.view(.buyTapped)) { $0.operation = .purchasing }
        await store.send(.view(.buyTapped))
        await store.send(.view(.restoreTapped))
        purchase.open()
        await store.receive(.internal(.purchaseFinished(.cancelled))) { $0.operation = nil }

        #expect(purchases.value == 1)
    }

    @Test(arguments: [PurchaseFeature.Offer.loading, .unavailable])
    func test_priceNotShown_buyDoesNothingButRestoreWorks(offer: PurchaseFeature.Offer) async {
        var state = sheet()
        state.offer = offer
        let store = makeStore(state) { $0.purchases.restore = { .cancelled } }

        await store.send(.view(.buyTapped))
        await store.send(.view(.restoreTapped)) { $0.operation = .restoring }
        await store.receive(.internal(.restoreFinished(.cancelled))) { $0.operation = nil }
    }

    @Test
    func test_restoreOffer_restoreRestoresAndOKCloses() async {
        var state = sheet()
        state.destination = .restoreOffer(.confirmationFailed)
        let store = makeStore(state) { $0.purchases.restore = { .cancelled } }

        await store.send(.destination(.presented(.restoreOffer(.restore)))) {
            $0.destination = nil
            $0.operation = .restoring
        }
        await store.receive(.internal(.restoreFinished(.cancelled))) { $0.operation = nil }

        var offered = sheet()
        offered.destination = .restoreOffer(.purchaseUnverified)
        await makeStore(offered).send(.destination(.dismiss)) { $0.destination = nil }
    }
}
