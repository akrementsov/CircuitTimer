import Dependencies
import DependenciesMacros
import Foundation
import HealthKit

/// Whether the timer can hold a workout session, and whether iOS still has to ask for Health access first.
public enum HealthAccess: Equatable, Sendable {
    /// Before iOS 26, or on a device without Health: the timer runs as it always has.
    case unavailable
    /// iOS has not asked yet; asking shows the Health sheet.
    case notDetermined
    /// iOS has asked, whatever the answer: it never tells the app that writing was refused.
    case determined
}

/// A HealthKit workout session for each open timer, so that iOS keeps the app running in the background and lets it
/// end its Live Activity and notifications when it is closed. A session exists only on iOS 26 and later with Health
/// access; otherwise starting one does nothing.
@DependencyClient
public struct WorkoutHealthClient: Sendable {
    public var access: @Sendable () async throws -> HealthAccess
    /// Shows the Health sheet when iOS has not asked yet; returns once it is answered.
    public var requestAuthorization: @Sendable () async throws -> Void
    /// Starts the owner's session. Repeating it, or starting an owner that has ended, does nothing. While `endOrphans`
    /// is recovering an earlier session it waits at most `WorkoutSessions.recoveryTimeout` for it.
    public var start: @Sendable (_ owner: UUID, _ date: Date) async -> Void
    /// Ends the owner's session and discards what it recorded; the owner never starts again.
    public var end: @Sendable (_ owner: UUID, _ date: Date) async -> Void
    /// Synchronous, so the app delegate refuses every later start before it returns from termination.
    public var beginTermination: @Sendable () -> Void
    /// Ends every session.
    public var endAll: @Sendable (_ date: Date) async -> Void
    /// Ends a session an earlier process left running, once per process.
    public var endOrphans: @Sendable () async -> Void
}

/// iOS answered neither that it must ask nor that it has asked.
struct UnknownHealthAccess: Error {}

extension WorkoutHealthClient: DependencyKey {
    /// The one instance the store and the app delegate share.
    public static let liveValue: Self = {
        let store = HKHealthStore()
        let gate = TerminationGate()
        let sessions = WorkoutSessions(store: store, gate: gate)
        return Self(
            access: {
                guard #available(iOS 26, *), HKHealthStore.isHealthDataAvailable() else { return .unavailable }

                switch try await store.statusForAuthorizationRequest(toShare: [.workoutType()], read: []) {
                    case .shouldRequest: return .notDetermined
                    case .unnecessary: return .determined
                    case .unknown: throw UnknownHealthAccess()
                    @unknown default: throw UnknownHealthAccess()
                }
            },
            requestAuthorization: {
                guard #available(iOS 26, *), HKHealthStore.isHealthDataAvailable() else { return }

                try await store.requestAuthorization(toShare: [.workoutType()], read: [])
            },
            start: { owner, date in
                @Dependency(\.continuousClock) var clock
                await sessions.start(owner: owner, at: date, clock: clock)
            },
            end: { await sessions.end(owner: $0, at: $1) },
            beginTermination: { gate.close() },
            endAll: { await sessions.endAll(at: $0) },
            endOrphans: {
                @Dependency(\.continuousClock) var clock
                await sessions.endOrphans(clock: clock)
            }
        )
    }()

    /// Holds no session: a preview has no Health.
    public static let previewValue = Self(
        access: { .unavailable },
        requestAuthorization: {},
        start: { _, _ in },
        end: { _, _ in },
        beginTermination: {},
        endAll: { _ in },
        endOrphans: {}
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented.
    public static let testValue = Self()
}

extension DependencyValues {
    public var workoutHealth: WorkoutHealthClient {
        get { self[WorkoutHealthClient.self] }
        set { self[WorkoutHealthClient.self] = newValue }
    }
}
