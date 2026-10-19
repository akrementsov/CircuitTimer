import Dependencies
import DependenciesMacros
import Foundation

/// Whether the timer should warn that its activity cannot be shown. A newer state of the
/// coordinator always has a larger serial, whatever order the results reach the reducer in.
public struct LiveActivityNotice: Equatable, Sendable {
    public let serial: Int
    public let isFailing: Bool

    public init(serial: Int, isFailing: Bool) {
        self.serial = serial
        self.isFailing = isFailing
    }
}

/// The Live Activity of each timer owner: one activity per owner, started on the first sync
/// that iOS allows and kept in step with the newest revision.
@DependencyClient
public struct LiveActivityClient: Sendable {
    /// An increasing revision for the next `sync`. Take it in the reducer: effects can start out
    /// of order, and the coordinator drops a sync older than one it has accepted.
    public var nextRevision: @Sendable () -> Int = { 0 }
    /// Shows `content`; returns a notice only when the warning should change.
    public var sync: @Sendable (
        _ owner: UUID,
        _ revision: Int,
        _ attributes: WorkoutActivityAttributes,
        _ content: WorkoutActivityAttributes.ContentState
    ) async -> LiveActivityNotice? = { _, _, _, _ in nil }
    /// Removes the owner's activity at once and refuses its later syncs. Waits a bounded time
    /// (`LiveActivityCoordinator.endTimeout`); the removal finishes in the background after that.
    public var end: @Sendable (_ owner: UUID) async -> Void
    /// Removes the activities of earlier processes.
    public var endOrphans: @Sendable () async -> Void
    /// Subscribes the live timer before its first card is published.
    public var requests: @Sendable (_ owner: UUID) async -> AsyncStream<LiveActivityControlRequest> = { _ in
        AsyncStream { $0.finish() }
    }
    public var deliver: @Sendable (
        _ activityID: String, _ command: LiveActivityCommand, _ generation: Int
    ) async -> LiveActivityControlResult = { _, _, _ in .unavailable }
    public var requestHandled: @Sendable (
        _ owner: UUID, _ requestID: Int, _ result: LiveActivityControlResult
    ) async -> Void = { _, _, _ in }
}

extension LiveActivityClient: DependencyKey {
    public static let liveValue: Self = {
        let coordinator = LiveActivityCoordinator(transport: .live())
        let revision = LockIsolated(0)
        return Self(
            nextRevision: {
                revision.withValue {
                    $0 += 1
                    return $0
                }
            },
            sync: { owner, revision, attributes, content in
                @Dependency(\.continuousClock) var clock
                return await coordinator.sync(owner: owner, revision: revision, attributes: attributes, content: content, clock: clock)
            },
            end: { owner in
                @Dependency(\.continuousClock) var clock
                await coordinator.end(owner: owner, clock: clock)
            },
            endOrphans: { await coordinator.endOrphans() },
            requests: { _ in AsyncStream { $0.finish() } },
            deliver: { _, _, _ in .unavailable },
            requestHandled: { _, _, _ in }
        )
    }()

    /// Shows nothing: a preview has no Live Activities.
    public static let previewValue = Self(
        nextRevision: { 1 },
        sync: { _, _, _, _ in nil },
        end: { _ in },
        endOrphans: {},
        requests: { _ in AsyncStream { $0.finish() } },
        deliver: { _, _, _ in .unavailable },
        requestHandled: { _, _, _ in }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var liveActivity: LiveActivityClient {
        get { self[LiveActivityClient.self] }
        set { self[LiveActivityClient.self] = newValue }
    }
}
