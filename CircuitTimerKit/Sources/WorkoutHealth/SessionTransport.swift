import Foundation
import HealthKit

/// One workout session as `WorkoutSessions` drives it; HealthKit stays inside the closures.
struct SessionHandle: Sendable {
    /// The main activity's identifier: the same when recovery returns this session as another object.
    var activityID: @Sendable () -> UUID
    /// Becomes the session's delegate and returns what it reports, until `release`. A recovered session of this
    /// process is never observed: that would take the delegate from its owner.
    var observe: @Sendable () -> AsyncStream<SessionEvent>
    var start: @Sendable (Date) -> Void
    var stop: @Sendable (Date) -> Void
    /// HealthKit promises to end only a running or stopped session, not one that is still starting.
    var end: @Sendable () -> Void
    /// Discards what the session recorded and ends `observe`'s stream; the session itself is left as it is.
    var release: @Sendable () -> Void
}

/// HealthKit's workout sessions behind Sendable closures.
struct SessionTransport: Sendable {
    /// iOS 26 or later, with Health and write access to workouts.
    var canHoldSessions: @Sendable () -> Bool
    var create: @Sendable () throws -> SessionHandle
    /// The session an earlier process left running, if HealthKit has one.
    var recover: @Sendable () async throws -> SessionHandle?

    static func live(store: HKHealthStore) -> Self {
        Self(
            canHoldSessions: {
                guard #available(iOS 26, *), HKHealthStore.isHealthDataAvailable() else { return false }

                return store.authorizationStatus(for: .workoutType()) == .sharingAuthorized
            },
            create: {
                guard #available(iOS 26, *) else { throw HKError(.errorHealthDataUnavailable) }

                let configuration = HKWorkoutConfiguration()
                configuration.activityType = .highIntensityIntervalTraining
                configuration.locationType = .indoor
                return handle(try HKWorkoutSession(healthStore: store, configuration: configuration))
            },
            recover: {
                guard #available(iOS 26, *) else { return nil }

                return try await store.recoverActiveWorkoutSession().map(handle)
            }
        )
    }

    @available(iOS 26, *)
    private static func handle(_ session: HKWorkoutSession) -> SessionHandle {
        let events = SessionEvents()
        let builder = session.associatedWorkoutBuilder()
        return SessionHandle(
            activityID: { session.currentActivity.uuid },
            observe: {
                session.delegate = events
                return events.stream
            },
            start: { session.startActivity(with: $0) },
            stop: { session.stopActivity(with: $0) },
            end: { session.end() },
            release: {
                builder.discardWorkout()
                events.finish()
            }
        )
    }
}
