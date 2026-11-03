import Dependencies
import DependenciesMacros
import Foundation
import os
import WorkoutActivity
#if os(iOS)
import WatchConnectivity
#endif

/// The iPhone publishes its workout list and its running workout to the watch and answers the watch's requests.
@DependencyClient
public struct WatchCompanionClient: Sendable {
    /// Starts the session once per process, before the first scene: a request from the watch may have launched it.
    public var activate: @Sendable () -> Void
    /// An increasing revision for the next `publishCatalog` or `publishRun`. Take it in the reducer: effects can start
    /// out of order, and a publication older than one already handled is dropped.
    public var nextRevision: @Sendable () -> Int = { 0 }
    public var publishCatalog: @Sendable (_ revision: Int, _ catalog: CatalogState) async -> Void
    /// Publishes the timer's settled run; its owner is `run.owner`.
    public var publishRun: @Sendable (_ revision: Int, _ run: WatchRun) async -> Void
    /// Ends the owner's run at once: no later publication carries it. The state without it is written and sent
    /// without the caller waiting for the write.
    public var end: @Sendable (_ owner: UUID) async -> Void
    /// Synchronous, for termination: closes every publication; only `finishTermination` writes after it.
    public var beginTermination: @Sendable () -> Void
    /// Writes the state without any run. The caller bounds the wait.
    public var finishTermination: @Sendable () async -> Void
    /// The watch's requests for the owner's timer; a new subscription replaces the owner's previous one.
    public var controlRequests: @Sendable (_ owner: UUID) async -> AsyncStream<WatchControlRequest> = { _ in
        AsyncStream { $0.finish() }
    }
    /// The timer's answer to a request: its settled run, or `nil` when it cannot publish one. The run is published
    /// whether or not the request still waits.
    public var refreshHandled: @Sendable (_ owner: UUID, _ requestID: Int, _ publication: WatchRunPublication?) async -> Void
    /// The timer's answer to a command, after the syncs its rules wait for: what it did and its run as published then,
    /// or `nil` when it publishes none. The run is published whether or not the command still waits.
    public var controlHandled: @Sendable (
        _ owner: UUID,
        _ requestID: Int,
        _ result: LiveActivityControlResult,
        _ publication: WatchRunPublication?
    ) async -> Void
    /// The app's Start requests; only one subscriber is active, independently of the timer's control channel.
    public var startRequests: @Sendable () async -> AsyncStream<WatchStartRequest> = { AsyncStream { $0.finish() } }
    /// Returns false after admission expired or the subscriber ended. True admits work, not delivery of the reply.
    public var startHandled: @Sendable (_ requestID: Int, _ result: WatchStartResult) async -> Bool = { _, _ in false }
}

extension WatchCompanionClient: DependencyKey {
    public static let liveValue: Self = {
        #if os(iOS)
        @Dependency(\.uuid) var uuid
        @Dependency(\.date) var date
        @Dependency(\.continuousClock) var clock
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
                        now: { date.now },
                        clock: clock
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
            },
            publishRun: { revision, run in
                await companion.value?.publishRun(revision: revision, run: run)
            },
            end: { owner in
                guard let started = companion.value else { return }
                started.markEnded(owner)
                // The closing timer waits for nothing but the mark above; the actor numbers and writes the rest.
                // swiftlint:disable:next no_unstructured_task
                Task { await started.end(owner: owner) }
            },
            beginTermination: {
                companion.value?.closeGate()
            },
            finishTermination: {
                await companion.value?.finishTermination()
            },
            controlRequests: { owner in
                guard let started = companion.value else { return AsyncStream { $0.finish() } }
                return await started.controlRequests(owner: owner)
            },
            refreshHandled: { owner, requestID, publication in
                await companion.value?.refreshHandled(owner: owner, requestID: requestID, publication: publication)
            },
            controlHandled: { owner, requestID, result, publication in
                await companion.value?.controlHandled(
                    owner: owner,
                    requestID: requestID,
                    result: result,
                    publication: publication
                )
            },
            startRequests: {
                guard let started = companion.value else { return AsyncStream { $0.finish() } }
                return await started.startRequests()
            },
            startHandled: { requestID, result in
                await companion.value?.startHandled(requestID: requestID, result: result) ?? false
            }
        )
        #else
        let misuse: @Sendable () -> Void = {
            Logger.watchLink.error("The iPhone's link client was used on the watch")
        }
        return Self(
            activate: misuse,
            nextRevision: { 0 },
            publishCatalog: { _, _ in misuse() },
            publishRun: { _, _ in misuse() },
            end: { _ in misuse() },
            beginTermination: misuse,
            finishTermination: misuse,
            controlRequests: { _ in
                misuse()
                return AsyncStream { $0.finish() }
            },
            refreshHandled: { _, _, _ in misuse() },
            controlHandled: { _, _, _, _ in misuse() },
            startRequests: {
                misuse()
                return AsyncStream { $0.finish() }
            },
            startHandled: { _, _ in
                misuse()
                return false
            }
        )
        #endif
    }()

    /// Talks to no watch.
    public static let previewValue = Self(
        activate: {},
        nextRevision: { 1 },
        publishCatalog: { _, _ in },
        publishRun: { _, _ in },
        end: { _ in },
        beginTermination: {},
        finishTermination: {},
        controlRequests: { _ in AsyncStream { $0.finish() } },
        refreshHandled: { _, _, _ in },
        controlHandled: { _, _, _, _ in },
        startRequests: { AsyncStream { $0.finish() } },
        startHandled: { _, _ in false }
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
