import ComposableArchitecture

extension AlertState where Action == Never {
    static var purchaseFailed: Self {
        AlertState {
            TextState("purchase.alert.purchaseFailed.title", bundle: .module)
        } message: {
            TextState("purchase.alert.purchaseFailed.message", bundle: .module)
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

    /// StoreKit said yes, but the full version was not published in time; restoring reads it again.
    static var confirmationFailed: Self {
        AlertState {
            TextState("purchase.alert.confirmationFailed.title", bundle: .module)
        } message: {
            TextState("purchase.alert.confirmationFailed.message", bundle: .module)
        }
    }
}
