import Dependencies
import DependenciesMacros
import Foundation
import os
#if os(iOS)
import WatchConnectivity
#endif

/// The iPhone publishes its workout list to the watch and answers the watch's requests.
@DependencyClient
public struct WatchCompanionClient: Sendable {
    /// Starts the session once per process, before the first scene: a request from the watch may have launched it.
    public var activate: @Sendable () -> Void
    /// An increasing revision for the next `publishCatalog`. Take it in the reducer: effects can start out of order,
    /// and a publication older than one already handled is dropped.
    public var nextRevision: @Sendable () -> Int = { 0 }
    public var publishCatalog: @Sendable (_ revision: Int, _ catalog: CatalogState) async -> Void
}

extension WatchCompanionClient: DependencyKey {
    public static let liveValue: Self = {
        #if os(iOS)
        @Dependency(\.uuid) var uuid
        @Dependency(\.date) var date
        let companion = LockIsolated<WatchCompanion?>(nil)
        let revision = LockIsolated(0)
        return Self(
            activate: {
                companion.withValue { companion in
                    // `WCSession.default` must not be touched where WatchConnectivity is unsupported, such as an iPad.
                    guard companion == nil, WCSession.isSupported() else { return }
                    let transport = WCSessionBridge().transport
                    let started = WatchCompanion(
                        ledger: PublicationLedger(processID: uuid(), transport: transport),
                        transport: transport,
                        now: { date.now }
                    )
                    // Subscribe before activating, so the request that launched the app reaches the actor.
                    let events = transport.events()
                    // The actor reads the session's events for the life of the process.
                    // swiftlint:disable:next no_unstructured_task
                    Task { await started.run(events) }
                    transport.activate()
                    companion = started
                }
            },
            nextRevision: {
                revision.withValue {
                    $0 += 1
                    return $0
                }
            },
            publishCatalog: { revision, catalog in
                await companion.value?.publishCatalog(revision: revision, catalog: catalog)
            }
        )
        #else
        return Self(
            activate: { Logger.watchLink.error("The iPhone's link client was activated on the watch") },
            nextRevision: { 0 },
            publishCatalog: { _, _ in Logger.watchLink.error("The iPhone's link client published on the watch") }
        )
        #endif
    }()

    /// Talks to no watch.
    public static let previewValue = Self(
        activate: {},
        nextRevision: { 1 },
        publishCatalog: { _, _ in }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var watchCompanion: WatchCompanionClient {
        get { self[WatchCompanionClient.self] }
        set { self[WatchCompanionClient.self] = newValue }
    }
}
