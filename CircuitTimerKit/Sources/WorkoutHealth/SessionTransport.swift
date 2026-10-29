import Foundation
import HealthKit
import os

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
    /// Saves a workout with a builder of its own, which needs no session: the session's own builder would have to
    /// start collecting with the session and stop with it, which neither a late start nor a lost session allows.
    var save: @Sendable (HealthWorkout) async throws -> Void

    static func live(store: HKHealthStore) -> Self {
        Self(
            canHoldSessions: {
                guard #available(iOS 26, *), HKHealthStore.isHealthDataAvailable() else { return false }

                return store.authorizationStatus(for: .workoutType()) == .sharingAuthorized
            },
            create: {
                guard #available(iOS 26, *) else { throw HKError(.errorHealthDataUnavailable) }

                return handle(try HKWorkoutSession(healthStore: store, configuration: makeConfiguration()))
            },
            recover: {
                guard #available(iOS 26, *) else { return nil }

                return try await store.recoverActiveWorkoutSession().map(handle)
            },
            save: { workout in
                let builder = HKWorkoutBuilder(healthStore: store, configuration: makeConfiguration(), device: .local())
                try await builder.beginCollection(at: workout.start)
                // Pause and resume events take the pauses out of the workout's duration.
                let events = workout.pauses.flatMap { pause in
                    [
                        HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil),
                        HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.end, duration: 0), metadata: nil),
                    ]
                }
                do {
                    if !events.isEmpty {
                        try await builder.addWorkoutEvents(events)
                    }
                    try await builder.endCollection(at: workout.end)
                    if try await builder.finishWorkout() == nil {
                        // Saved, but HealthKit cannot hand the sample back while the device is locked.
                        Logger.workoutHealth.notice("Saved a workout to Health while the device was locked")
                    }
                } catch {
                    // A collecting builder keeps the store until it is finished or discarded.
                    builder.discardWorkout()
                    throw error
                }
            }
        )
    }

    /// A new configuration each time: HealthKit's configuration is a mutable class.
    private static func makeConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .highIntensityIntervalTraining
        configuration.locationType = .indoor
        return configuration
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
                // The session's own builder never saves; `SessionTransport.save` does.
                builder.discardWorkout()
                events.finish()
            }
        )
    }
}
