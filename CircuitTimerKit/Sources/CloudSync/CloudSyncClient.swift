import CloudKit
import Dependencies
import DependenciesMacros
import Foundation
import Sharing

/// Whether this launch syncs workouts through iCloud, and how that goes. The decision is the one point where a
/// purchase can later lock sync.
@DependencyClient
public struct CloudSyncClient: Sendable {
    /// The CloudKit container the store mirrors to in this launch, or `nil` to keep it on the device. The first call
    /// decides; the same answer follows until the app is launched again.
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
                @SharedReader(.iCloudSync) var isICloudSyncOn
                return isICloudSyncOn
            },
            containerID: { CloudKitContainerID.inMainBundle() },
            accountStatus: { try await CKContainer(identifier: $0).accountStatus() }
        )
        return Self(
            mirroredContainer: { monitor.mirroredContainer() },
            storeOpened: { monitor.storeOpened(isMirroring: $0) },
            status: { monitor.status() },
            remoteChanges: { monitor.remoteChanges() }
        )
    }()

    /// Keeps the store on the device and reports nothing: a preview has no iCloud.
    public static let previewValue = Self(
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
