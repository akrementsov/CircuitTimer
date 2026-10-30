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
/// end its Live Activity and notifications when it is closed, and its workout saved to Health when the session ends. A
/// session exists only on iOS 26 and later with Health access; otherwise starting one does nothing and nothing is saved.
@DependencyClient
public struct WorkoutHealthClient: Sendable {
    public var access: @Sendable () async throws -> HealthAccess
    /// Shows the Health sheet when iOS has not asked yet; returns once it is answered.
    public var requestAuthorization: @Sendable () async throws -> Void
    /// Starts the owner's session. Repeating it, or starting an owner that has ended, does nothing. While `endOrphans`
    /// is recovering an earlier session it waits at most 2 seconds for it.
    public var start: @Sendable (_ owner: UUID, _ date: Date) async -> Void
    /// Keeps the owner's newest track, so the session can save the run up to wherever it stands when it closes. An
    /// older revision, an owner that has ended or one whose session was lost is ignored, except that the first track
    /// of an owner lost before any track arrived is saved up to the loss, whatever its revision.
    public var sync: @Sendable (_ owner: UUID, _ revision: Int, _ track: WorkoutHealthTrack) async -> Void
    /// Ends the owner's session and saves the workout of its final track up to `date`, if the run ran; the owner never
    /// starts again.
    public var end: @Sendable (_ owner: UUID, _ track: WorkoutHealthTrack, _ date: Date) async -> Void
    /// Synchronous, so the app delegate refuses every later start before it returns from termination.
    public var beginTermination: @Sendable () -> Void
    /// Ends every session, saving each owner's newest track up to `date`, and waits until HealthKit reports each one
    /// ended and every workout is saved.
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
        let sessions = WorkoutSessions(transport: .live(store: store), gate: gate) {
            @Dependency(\.date) var date
            return date.now
        }
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
            sync: { owner, revision, track in
                await sessions.sync(owner: owner, revision: revision, track: track)
            },
            end: { owner, track, date in
                @Dependency(\.continuousClock) var clock
                await sessions.end(owner: owner, track: track, at: date, clock: clock)
            },
            beginTermination: { gate.close() },
            endAll: { date in
                @Dependency(\.continuousClock) var clock
                await sessions.endAll(at: date, clock: clock)
            },
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
        sync: { _, _, _ in },
        end: { _, _, _ in },
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
