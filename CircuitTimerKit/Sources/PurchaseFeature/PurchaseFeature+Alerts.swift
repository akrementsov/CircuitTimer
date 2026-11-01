import ComposableArchitecture
import SwiftUI

extension AlertState where Action == Never {
    static var purchaseFailed: Self {
        AlertState {
            TextState("purchase.alert.purchaseFailed.title", bundle: .module)
        } message: {
            TextState("purchase.alert.purchaseFailed.message", bundle: .module)
        }
    }

    static var purchaseNotAllowed: Self {
        AlertState {
            TextState("purchase.alert.notAllowed.title", bundle: .module)
        } message: {
            TextState("purchase.alert.notAllowed.message", bundle: .module)
        }
    }

    static var nothingToRestore: Self {
        AlertState {
            TextState("purchase.alert.nothingToRestore.title", bundle: .module)
        } message: {
            TextState("purchase.alert.nothingToRestore.message", bundle: .module)
        }
    }

    static var restoreFailed: Self {
        AlertState {
            TextState("purchase.alert.restoreFailed.title", bundle: .module)
        } message: {
            TextState("purchase.alert.restoreFailed.message", bundle: .module)
        }
    }
}

extension AlertState where Action == PurchaseFeature.RestoreOfferChoice {
    /// StoreKit said yes, but the full version was not published in time.
    static var confirmationFailed: Self {
        restoreOffer(title: "purchase.alert.confirmationFailed.title", message: "purchase.alert.confirmationFailed.message")
    }

    /// StoreKit could not verify the purchase; the payment may have gone through.
    static var purchaseUnverified: Self {
        restoreOffer(title: "purchase.alert.unverified.title", message: "purchase.alert.unverified.message")
    }

    private static func restoreOffer(title: LocalizedStringKey, message: LocalizedStringKey) -> Self {
        AlertState {
            TextState(title, bundle: .module)
        } actions: {
            ButtonState(action: .restore) {
                TextState("purchase.restore", bundle: .module)
            }
            ButtonState(role: .cancel) {
                TextState("purchase.alert.ok", bundle: .module)
            }
        } message: {
            TextState(message, bundle: .module)
        }
    }
}
