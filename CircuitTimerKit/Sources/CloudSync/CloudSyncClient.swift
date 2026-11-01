import CloudKit
import Dependencies
import DependenciesMacros
import Foundation
import Purchases
import Sharing
import os

/// Whether this launch syncs workouts through iCloud, and how that goes.
@DependencyClient
public struct CloudSyncClient: Sendable {
    // The defaults are what the unimplemented `testValue` returns after reporting the call.

    /// Waits, once per process, for what the launch decision needs (the full version, at most a second), then decides.
    /// A cancelled caller still waits for it, and a cancellation never decides.
    public var prepareDecision: @Sendable () async -> Void = {}
    /// The CloudKit container the store mirrors to in this launch, or `nil` to keep it on the device. The first call
    /// decides, unless `prepareDecision` already has; the same answer follows until the app is launched again.
    public var mirroredContainer: @Sendable () -> String? = { nil }
    /// How the store actually opened, which can differ from the decision when mirroring failed to open.
    public var storeOpened: @Sendable (_ isMirroring: Bool) -> Void
    /// The current status, then every change of it.
    public var status: @Sendable () async -> AsyncStream<CloudSyncStatus> = { AsyncStream { $0.finish() } }
    /// One element whenever the store may have changed without a write of this device.
    public var remoteChanges: @Sendable () async -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
}

/// The container the app's Info.plist names under `CTCloudKitContainerIdentifier`. Unsigned builds empty it, because
/// they carry no iCloud entitlement.
public enum CloudKitContainerID {
    public static func inMainBundle() -> String? {
        guard let container = Bundle.main.object(forInfoDictionaryKey: "CTCloudKitContainerIdentifier") as? String,
              !container.isEmpty else { return nil }

        return container
    }
}

extension CloudSyncClient: DependencyKey {
    public static let liveValue: Self = {
        let monitor = CloudSyncMonitor(
            notificationCenter: .default,
            preference: {
                // iCloud sync is part of the full version.
                @SharedReader(.iCloudSync) var isICloudSyncOn
                @Dependency(\.purchases) var purchases
                return isICloudSyncOn && purchases.currentStatus() == .full
            },
            containerID: { CloudKitContainerID.inMainBundle() },
            accountStatus: { try await CKContainer(identifier: $0).accountStatus() },
            prepareInputs: {
                @Dependency(\.purchases) var purchases
                if await purchases.refreshStatus(.seconds(1)) == .unknown {
                    CloudSyncMonitor.logger.error("StoreKit did not answer in time; this launch keeps workouts on the device")
                }
            }
        )
        return Self(
            prepareDecision: { await monitor.prepareDecision() },
            mirroredContainer: { monitor.mirroredContainer() },
            storeOpened: { monitor.storeOpened(isMirroring: $0) },
            status: { monitor.status() },
            remoteChanges: { monitor.remoteChanges() }
        )
    }()

    /// Keeps the store on the device and reports nothing: a preview has no iCloud.
    public static let previewValue = Self(
        prepareDecision: {},
        mirroredContainer: { nil },
        storeOpened: { _ in },
        status: { AsyncStream { $0.finish() } },
        remoteChanges: { AsyncStream { $0.finish() } }
    )
    public static let testValue = Self()
}

extension DependencyValues {
    public var cloudSync: CloudSyncClient {
        get { self[CloudSyncClient.self] }
        set { self[CloudSyncClient.self] = newValue }
    }
}
