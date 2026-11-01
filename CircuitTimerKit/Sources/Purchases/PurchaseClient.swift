import Dependencies
import DependenciesMacros
import Foundation

/// The full version: whether this Apple ID owns it, its price, and buying or restoring it through StoreKit 2.
@DependencyClient
public struct PurchaseClient: Sendable {
    // The defaults are what the unimplemented `testValue` returns after reporting the call.

    /// What the process knows now; `.unknown` until StoreKit has answered once.
    public var currentStatus: @Sendable () -> FullVersionStatus = { .unknown }
    /// The first known status, or the current one after `timeout`. A cancelled caller gets the current one at once.
    public var refreshStatus: @Sendable (_ timeout: Duration) async -> FullVersionStatus = { _ in .unknown }
    /// The current status at once, then every change of it.
    public var changes: @Sendable () async -> AsyncStream<FullVersionStatus> = { AsyncStream { $0.finish() } }
    public var offer: @Sendable () async throws -> FullVersionOffer
    /// A verified purchase is finished, and the full version published, before this returns.
    public var purchase: @Sendable () async throws -> PurchaseOutcome
    /// `AppStore.sync()`, then the entitlement read again; the outcome is that read's own answer, or a newer one that
    /// found the full version.
    public var restore: @Sendable () async throws -> RestoreOutcome
}

extension PurchaseClient: DependencyKey {
    /// The one monitor of the process: its listener of transaction updates runs from the first use on.
    public static let liveValue: Self = {
        let monitor = EntitlementMonitor(transport: .live()) { duration in
            @Dependency(\.continuousClock) var clock
            try await clock.sleep(for: duration)
        }
        return Self(
            currentStatus: { monitor.currentStatus },
            refreshStatus: { await monitor.refreshStatus(timeout: $0) },
            changes: { monitor.changes() },
            offer: { try await monitor.offer() },
            purchase: { try await monitor.purchase() },
            restore: { try await monitor.restore() }
        )
    }()

    /// Never reaches StoreKit and changes nothing. `changes` finishes without a status: a preview or a snapshot shows
    /// the state it was built with, and a status yielded after its first frame would change it.
    public static let previewValue = Self(
        currentStatus: { .free },
        refreshStatus: { _ in .free },
        changes: { AsyncStream { $0.finish() } },
        offer: { FullVersionOffer(displayPrice: "$0.99") },
        purchase: { .purchased },
        restore: { .nothingFound }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var purchases: PurchaseClient {
        get { self[PurchaseClient.self] }
        set { self[PurchaseClient.self] = newValue }
    }
}
