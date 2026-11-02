@testable import PurchaseFeature

import ComposableArchitecture
import Foundation
import Purchases
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PurchaseFeatureOutcomeTests {
    // MARK: - Success

    @Test(arguments: [PurchaseFeature.Operation.purchasing, .restoring])
    func test_success_fullAlreadyPublished_showsSuccessAtOnce(operation: PurchaseFeature.Operation) async {
        let store = makeStore(sheet(operation: operation))

        // The monitor publishes the full version before the operation returns; the sheet stays for its own success.
        await store.send(.internal(.statusChanged(.full))) { $0.status = .full }
        await store.send(.internal(succeeded(operation))) {
            $0.operation = nil
            $0.didUnlockHere = true
        }
        #expect(store.state.isShowingSuccess)
    }

    @Test(arguments: [PurchaseFeature.Operation.purchasing, .restoring])
    func test_success_whileFree_awaitsConfirmationAndAFullInTimeShowsSuccess(operation: PurchaseFeature.Operation) async {
        let clock = TestClock()
        let store = makeStore(sheet(operation: operation)) { $0.continuousClock = clock }

        await store.send(.internal(succeeded(operation))) {
            $0.operation = nil
            $0.expectsUnlock = true
            $0.isAwaitingConfirmation = true
        }
        await clock.advance(by: .seconds(2))
        await store.send(.internal(.statusChanged(.full))) {
            $0.status = .full
            $0.didUnlockHere = true
            $0.expectsUnlock = false
            $0.isAwaitingConfirmation = false
        }
        await clock.advance(by: .seconds(5))
        await store.finish()
    }

    @Test
    func test_success_staleAfterARefund_isBoundedByTheTimeoutAndALateFullStillShowsSuccess() async {
        let clock = TestClock()
        let store = makeStore(sheet(operation: .purchasing)) { $0.continuousClock = clock }
        await store.send(.internal(.statusChanged(.full))) { $0.status = .full }
        await store.send(.internal(.statusChanged(.free))) { $0.status = .free }

        await store.send(.internal(.purchaseFinished(.purchased))) {
            $0.operation = nil
            $0.expectsUnlock = true
            $0.isAwaitingConfirmation = true
        }
        await clock.advance(by: PurchaseFeature.confirmationTimeout)
        await store.receive(.internal(.confirmationTimedOut)) {
            $0.isAwaitingConfirmation = false
            $0.destination = .restoreOffer(.confirmationFailed)
        }

        await store.send(.internal(.statusChanged(.full))) {
            $0.status = .full
            $0.didUnlockHere = true
            $0.expectsUnlock = false
            $0.destination = nil
        }
    }

    @Test
    func test_confirmationTimedOut_notAwaiting_isIgnored() async {
        await makeStore(sheet()).send(.internal(.confirmationTimedOut))
    }

    // MARK: - Failures

    @Test(arguments: [
        (PurchaseClientError.notAllowed, PurchaseFeature.PurchaseFailure.notAllowed),
        (.unverified, .unverified),
        (.productNotFound, .other),
        (nil, .other),
    ] as [(PurchaseClientError?, PurchaseFeature.PurchaseFailure)])
    func test_purchase_failing_showsTheAlertOfItsKind(error: PurchaseClientError?, failure: PurchaseFeature.PurchaseFailure) async {
        let store = makeStore(sheet()) {
            $0.purchases.purchase = {
                if let error { throw error }
                throw StoreFailure()
            }
        }

        await store.send(.view(.buyTapped)) { $0.operation = .purchasing }
        await store.receive(.internal(.purchaseFailed(failure))) {
            $0.operation = nil
            $0.destination = switch failure {
                case .notAllowed: .alert(.purchaseNotAllowed)
                case .unverified: .restoreOffer(.purchaseUnverified)
                case .other: .alert(.purchaseFailed)
            }
        }
    }

    @Test(arguments: ["purchaseFailed", "restoreFailed", "nothingFound"])
    func test_failure_fullFromElsewhereMeanwhile_closesWithoutAnAlert(outcome: String) async {
        let operation: PurchaseFeature.Operation = outcome == "purchaseFailed" ? .purchasing : .restoring
        let store = makeStore(sheet(operation: operation))
        await store.send(.internal(.statusChanged(.full))) { $0.status = .full }

        let action: PurchaseFeature.Action.Internal = switch outcome {
            case "purchaseFailed": .purchaseFailed(.other)
            case "restoreFailed": .restoreFailed
            default: .restoreFinished(.nothingFound)
        }
        await store.send(.internal(action)) { $0.operation = nil }
        await store.receive(.delegate(.closeRequested))
    }

    @Test
    func test_restoreOutcomes_whileFree_alertForNothingFoundAndFailureOnly() async {
        let nothingFound = makeStore(sheet(operation: .restoring))
        await nothingFound.send(.internal(.restoreFinished(.nothingFound))) {
            $0.operation = nil
            $0.destination = .alert(.nothingToRestore)
        }

        let failed = makeStore(sheet(operation: .restoring))
        await failed.send(.internal(.restoreFailed)) {
            $0.operation = nil
            $0.destination = .alert(.restoreFailed)
        }

        let cancelledRestore = makeStore(sheet(operation: .restoring))
        await cancelledRestore.send(.internal(.restoreFinished(.cancelled))) { $0.operation = nil }

        let cancelledPurchase = makeStore(sheet(operation: .purchasing))
        await cancelledPurchase.send(.internal(.purchaseFinished(.cancelled))) { $0.operation = nil }
    }

    // MARK: - Status changes

    @Test
    func test_fullFromElsewhere_closesAnIdleSheetButNotOneInAnOperation() async {
        let idle = makeStore(sheet())
        await idle.send(.internal(.statusChanged(.full))) { $0.status = .full }
        await idle.receive(.delegate(.closeRequested))

        let busy = makeStore(sheet(operation: .restoring))
        await busy.send(.internal(.statusChanged(.full))) { $0.status = .full }
    }

    @Test
    func test_askToBuy_pendingThenApproved_showsSuccess() async {
        let store = makeStore(sheet(operation: .purchasing))

        await store.send(.internal(.purchaseFinished(.pending))) {
            $0.operation = nil
            $0.isPending = true
        }
        await store.send(.internal(.statusChanged(.full))) {
            $0.status = .full
            $0.didUnlockHere = true
            $0.isPending = false
        }
        #expect(store.state.isShowingSuccess)
    }

    @Test
    func test_askToBuy_approvedBeforeThePendingResult_showsSuccess() async {
        let store = makeStore(sheet(operation: .purchasing))

        await store.send(.internal(.statusChanged(.full))) { $0.status = .full }
        await store.send(.internal(.purchaseFinished(.pending))) {
            $0.operation = nil
            $0.didUnlockHere = true
        }
        #expect(store.state.isShowingSuccess)
    }

    @Test
    func test_free_afterFullReturnsTheOfferAfterUnknownResetsNothing() async {
        var unlocked = sheet(status: .full)
        unlocked.didUnlockHere = true
        let refunded = makeStore(unlocked)
        await refunded.send(.internal(.statusChanged(.free))) {
            $0.status = .free
            $0.didUnlockHere = false
        }

        var pending = sheet(status: .unknown)
        pending.isPending = true
        let firstAnswer = makeStore(pending)
        await firstAnswer.send(.internal(.statusChanged(.free))) { $0.status = .free }
    }

    @Test
    func test_note_eachState_saysWhatItsMainButtonNeeds() {
        #expect(sheet().note == nil)
        #expect(sheet(operation: .purchasing).note == nil)

        var unlocked = sheet(status: .full)
        unlocked.didUnlockHere = true
        #expect(unlocked.note == .iCloudNextLaunch)

        var pending = sheet()
        pending.isPending = true
        #expect(pending.note == .pending)

        var unavailable = sheet()
        unavailable.offer = .unavailable
        #expect(unavailable.note == .unavailable)
    }

    private func succeeded(_ operation: PurchaseFeature.Operation) -> PurchaseFeature.Action.Internal {
        operation == .purchasing ? .purchaseFinished(.purchased) : .restoreFinished(.restored)
    }
}
