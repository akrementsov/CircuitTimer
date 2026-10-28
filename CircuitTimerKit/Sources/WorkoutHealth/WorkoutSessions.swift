import Foundation
import HealthKit
import os

/// One workout session per timer owner. The actor exists on every iOS version; only creating and recovering a session
/// needs iOS 26, so everything else stays callable and does nothing without a session.
actor WorkoutSessions {
    /// How long a start waits for the recovery of an earlier process's session, and recovery for that session to end.
    static let recoveryTimeout: Duration = .seconds(2)

    private struct Session {
        let session: HKWorkoutSession
        let builder: HKWorkoutBuilder
        let events: SessionEvents
        let watch: Task<Void, Never>
        let startDate: Date
    }

    private enum Slot {
        /// Waiting for recovery before the session is created.
        case reserved
        /// Created and asked to start; HealthKit reports `running` or a failure asynchronously.
        case starting(Session)
        case running(Session)
        /// Stopped by HealthKit after it ran. Not started again: from the background it cannot start, and a start on
        /// return would split the workout.
        case lost

        var session: Session? {
            switch self {
                case let .starting(session), let .running(session): session
                case .reserved, .lost: nil
            }
        }
    }

    private let store: HKHealthStore
    private let gate: TerminationGate
    private var slots: [UUID: Slot] = [:]
    /// Owners that have ended: a late or repeated start must not bring their session back.
    private var ended: Set<UUID> = []
    private var hasRecovered = false
    private var isRecovering = false
    private var hasEndedOrphan = false
    private var recoveryWaiters: [AsyncStream<Void>.Continuation] = []
    /// Starts that failed because recovery had not yet ended an earlier session; each runs once more after recovery.
    private var retryAfterRecovery: [UUID: Date] = [:]
    /// Owners already started once more, so a session that keeps failing is not retried in a loop.
    private var retried: Set<UUID> = []

    init(store: HKHealthStore, gate: TerminationGate) {
        self.store = store
        self.gate = gate
    }

    func start(owner: UUID, at date: Date, clock: any Clock<Duration>) async {
        guard canStart(owner) else { return }

        if isRecovering {
            slots[owner] = .reserved
            let (stream, waiter) = AsyncStream<Void>.makeStream()
            recoveryWaiters.append(waiter)
            let isRecovered = await Self.finishes(within: Self.recoveryTimeout, clock: clock) {
                for await _ in stream {}
            }
            if !isRecovered {
                Logger.workoutHealth.notice("Starting a workout session before recovery of an earlier one finished")
            }
            // `end` may have run during the wait and removed the reservation.
            guard case .reserved = slots[owner] else { return }

            slots[owner] = nil
            guard canStart(owner) else { return }
        }
        admit(owner, at: date)
    }

    func end(owner: UUID, at date: Date) {
        ended.insert(owner)
        retryAfterRecovery[owner] = nil
        guard let slot = slots.removeValue(forKey: owner) else { return }

        switch slot {
            case let .running(session):
                session.session.stopActivity(with: date)
                session.session.end()
                release(session)
            case let .starting(session):
                session.session.end()
                release(session)
            case .reserved, .lost:
                break
        }
    }

    func endAll(at date: Date) {
        for owner in slots.keys {
            end(owner: owner, at: date)
        }
    }

    /// Ends a session an earlier process left running, then retries the starts it blocked. Runs once per process.
    func endOrphans(clock: any Clock<Duration>) async {
        guard !hasRecovered else { return }

        hasRecovered = true
        guard #available(iOS 26, *),
              HKHealthStore.isHealthDataAvailable(),
              store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }

        isRecovering = true
        do {
            if let recovered = try await store.recoverActiveWorkoutSession() {
                await endIfOrphan(recovered, clock: clock)
            }
        } catch {
            Logger.workoutHealth.error("Recovering a workout session failed: \(String(reflecting: error), privacy: .public)")
        }
        isRecovering = false
        for waiter in recoveryWaiters {
            waiter.finish()
        }
        recoveryWaiters = []

        let retries = retryAfterRecovery
        retryAfterRecovery = [:]
        for (owner, date) in retries where canStart(owner) {
            retried.insert(owner)
            admit(owner, at: date)
        }
    }

    private func canStart(_ owner: UUID) -> Bool {
        !gate.isClosed && !ended.contains(owner) && slots[owner] == nil
    }

    private func admit(_ owner: UUID, at date: Date) {
        guard #available(iOS 26, *),
              store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .highIntensityIntervalTraining
        configuration.locationType = .indoor
        let session: HKWorkoutSession
        do {
            session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        } catch {
            Logger.workoutHealth.error("Creating a workout session failed: \(String(reflecting: error), privacy: .public)")
            return
        }

        let events = SessionEvents()
        session.delegate = events
        // Delegate callbacks arrive for as long as the session lives, outside any caller of this actor.
        // swiftlint:disable:next no_unstructured_task
        let watch = Task { [weak self] in
            for await event in events.stream {
                await self?.handle(event, of: session, owner: owner)
            }
        }
        slots[owner] = .starting(
            Session(session: session, builder: session.associatedWorkoutBuilder(), events: events, watch: watch, startDate: date)
        )
        session.startActivity(with: date)
    }

    private func handle(_ event: SessionEvent, of session: HKWorkoutSession, owner: UUID) {
        guard let slot = slots[owner], let current = slot.session, current.session === session else { return }

        switch (event, slot) {
            case (.changed(.running), .starting):
                slots[owner] = .running(current)
            case (.changed(.ended), .starting):
                Logger.workoutHealth.notice("A workout session ended before it ran")
                slots[owner] = nil
                release(current)
            case (.changed(.ended), .running):
                Logger.workoutHealth.error("HealthKit ended a running workout session")
                slots[owner] = .lost
                release(current)
            case let (.failed(error), .starting):
                slots[owner] = nil
                release(current)
                startFailed(owner, startDate: current.startDate, error: error)
            case let (.failed(error), .running):
                Logger.workoutHealth.error("A running workout session failed: \(String(reflecting: error), privacy: .public)")
                slots[owner] = .lost
                release(current)
            case (.changed, _), (.failed, _):
                break
        }
    }

    /// The next start, on the next active scene or after recovery, tries again.
    private func startFailed(_ owner: UUID, startDate: Date, error: any Error) {
        switch (error as? HKError)?.code {
            case .errorAnotherWorkoutSessionStarted:
                Logger.workoutHealth.notice("Another workout session is running")
                if isRecovering {
                    retryAfterRecovery[owner] = startDate
                } else if hasEndedOrphan, retried.insert(owner).inserted {
                    // Recovery has ended the other session, which may still have been ending when this one started.
                    admit(owner, at: startDate)
                }
            case .errorBackgroundWorkoutSessionNotAllowed:
                Logger.workoutHealth.notice("A workout session cannot start in the background")
            default:
                Logger.workoutHealth.error("Starting a workout session failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    /// Nothing is saved to Health in this release: whatever the session recorded is discarded.
    private func release(_ session: Session) {
        session.builder.discardWorkout()
        session.events.finish()
        session.watch.cancel()
    }

    @available(iOS 26, *)
    private func endIfOrphan(_ recovered: HKWorkoutSession, clock: any Clock<Duration>) async {
        // A start that stopped waiting for recovery may own the very session recovery returns, possibly as another
        // object; only another process's session is ended.
        let isOwn = slots.values.contains { slot in
            guard let own = slot.session?.session else { return false }

            return own === recovered || own.currentActivity.uuid == recovered.currentActivity.uuid
        }
        guard !isOwn else {
            Logger.workoutHealth.notice("Recovery returned a workout session of this process")
            return
        }

        let events = SessionEvents()
        recovered.delegate = events
        recovered.end()
        recovered.associatedWorkoutBuilder().discardWorkout()
        hasEndedOrphan = true
        Logger.workoutHealth.notice("Ended a workout session left by an earlier process")
        let didEnd = await Self.finishes(within: Self.recoveryTimeout, clock: clock) {
            for await event in events.stream {
                if case .changed(.ended) = event { return }
            }
        }
        if !didEnd {
            Logger.workoutHealth.notice("A workout session left by an earlier process did not report its end in time")
        }
        events.finish()
    }

    /// `false` when `timeout` passed first. `work` must return promptly once cancelled, so the wait never outlives
    /// `timeout`; whatever `work` was waiting for goes on without it.
    private static func finishes(
        within timeout: Duration,
        clock: any Clock<Duration>,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work()
                return !Task.isCancelled
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch is CancellationError {
                    return false
                } catch {
                    Logger.workoutHealth.error("A bounded wait failed: \(String(reflecting: error), privacy: .public)")
                }
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
