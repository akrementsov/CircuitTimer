/// Every call `EntitlementMonitor` makes to StoreKit, so its rules can be tested without the App Store.
struct StoreTransport: Sendable {
    var offer: @Sendable () async throws -> FullVersionOffer
    /// A verified purchase is finished before this returns.
    var purchase: @Sendable () async throws -> PurchaseOutcome
    /// `false` when the user cancelled the App Store sign-in.
    var sync: @Sendable () async throws -> Bool
    var isEntitled: @Sendable () async -> Bool
    /// Never returns: calls `handle` after every transaction update has been finished or rejected.
    var listen: @Sendable (_ handle: @escaping @Sendable () async -> Void) async -> Void
}
