/// Whether this Apple ID owns the full version, as far as the process knows.
public enum FullVersionStatus: Equatable, Sendable {
    /// StoreKit has not answered yet in this process.
    case unknown
    case free
    /// Bought, restored, shared through Family Sharing or approved after Ask to Buy, and not refunded or revoked.
    case full
}

/// What the purchase sheet offers: the price the App Store shows in the user's storefront.
public struct FullVersionOffer: Equatable, Sendable {
    public var displayPrice: String

    public init(displayPrice: String) {
        self.displayPrice = displayPrice
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    /// Waits for approval, such as Ask to Buy; an approval arrives later as a transaction update.
    case pending
    case cancelled
}

public enum RestoreOutcome: Equatable, Sendable {
    case restored
    case nothingFound
    /// The user cancelled the App Store sign-in.
    case cancelled
}

public enum PurchaseClientError: Error, Equatable, Sendable {
    /// The App Store returned no non-consumable with the full version's identifier.
    case productNotFound
    /// StoreKit could not verify the transaction's signature; it unlocks nothing.
    case unverified
    /// No scene of the app is in the foreground to show the payment sheet over.
    case noActiveScene
    /// A purchase result this version of the app does not know.
    case unknownResult
}
