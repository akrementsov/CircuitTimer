import Foundation
import HealthKit
import os

/// One workout session per timer owner. The actor exists on every iOS version; without iOS 26 and Health access its
/// transport holds no session, so everything stays callable and does nothing.
actor WorkoutSessions {
    /// How long a start waits for the recovery of an earlier process's session, and recovery for that session to end.
    static let recoveryTimeout: Duration = .seconds(2)
    /// A session that has not reported its end by then is logged; it stays held.
    static let endTimeout: Duration = .seconds(2)

    private struct HeldSession {
        let handle: SessionHandle
        /// Tells the events of an owner's later session from a released one's.
        let number: Int
        let watch: Task<Void, Never>
        let startDate: Date
        /// The start's clock, which times the save of a session lost on its own.
        let clock: any Clock<Duration>
    }

    private enum Slot {
        /// Waiting for recovery before the session is created.
        case reserved
        /// Created and asked to start; HealthKit reports `running` or a failure asynchronously.
        case starting(HeldSession)
        case running(HeldSession)
        /// Asked to end and kept until HealthKit reports it ended: one that was still starting may run first, and is
        /// ended again then.
        case ending(HeldSession)
        /// Stopped by HealthKit after it ran. Not started again: from the background it cannot start, and a start on
        /// return would split the workout. `unsavedLoss` is when it was lost before any track reached the actor: the
        /// first one to arrive is saved up to then.
        case lost(unsavedLoss: Date?, clock: any Clock<Duration>)

        var held: HeldSession? {
            switch self {
                case let .starting(held), let .running(held), let .ending(held): held
                case .reserved, .lost: nil
            }
        }

        var isEnding: Bool {
            if case .ending = self { true } else { false }
        }
    }

    private let transport: SessionTransport
    private let gate: TerminationGate
    private let now: @Sendable () -> Date
    private var slots: [UUID: Slot] = [:]
    /// Owners that have ended: a late or repeated start must not bring their session back.
    private var ended: Set<UUID> = []
    /// Each owner's newest track and its revision, kept with or without a session.
    private var tracks: [UUID: (revision: Int, track: WorkoutHealthTrack)] = [:]
    /// Saves still under way; `endAll` waits for them as for the sessions that are ending.
    private var saving: Set<Int> = []
    private var saveCount = 0
    private var sessionCount = 0
    private var hasRecovered = false
    private var isRecovering = false
    private var recoveryWaiters: [AsyncStream<Void>.Continuation] = []
    /// `endAll` callers waiting for the ending sessions to report their end and the saves to finish.
    private var endingWaiters: [AsyncStream<Void>.Continuation] = []

    init(transport: SessionTransport, gate: TerminationGate, now: @escaping @Sendable () -> Date) {
        self.transport = transport
        self.gate = gate
        self.now = now
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
            if !isRecovered, !Task.isCancelled {
                Logger.workoutHealth.notice("Starting a workout session before recovery of an earlier one finished")
            }
            // `end` may have run during the wait and removed the reservation.
            guard case .reserved = slots[owner] else { return }

            slots[owner] = nil
            guard canStart(owner) else { return }
        }
        admit(owner, at: date, clock: clock)
    }

    func sync(owner: UUID, revision: Int, track: WorkoutHealthTrack) {
        guard !ended.contains(owner) else { return }

        if case let .lost(unsavedLoss, clock) = slots[owner] {
            // The timer's effect can reach the actor after HealthKit reported the loss; a later track is never saved.
            if let unsavedLoss {
                slots[owner] = .lost(unsavedLoss: nil, clock: clock)
                save(track.workout(closingAt: now(), endingBy: unsavedLoss), clock: clock)
            }
            return
        }
        guard revision > tracks[owner]?.revision ?? .min else { return }

        tracks[owner] = (revision, track)
    }

    func end(owner: UUID, track: WorkoutHealthTrack, at date: Date, clock: any Clock<Duration>) {
        ended.insert(owner)
        tracks[owner] = nil
        switch slots[owner] {
            case let .running(held):
                // A wall clock moved back must not end the session before it started.
                held.handle.stop(max(date, held.startDate))
                held.handle.end()
                slots[owner] = .ending(held)
                watchEnd(of: held.number, owner: owner, clock: clock)
                save(track.workout(closingAt: date), clock: clock)
            case let .starting(held):
                held.handle.end()
                slots[owner] = .ending(held)
                watchEnd(of: held.number, owner: owner, clock: clock)
                save(track.workout(closingAt: date), clock: clock)
            case let .lost(unsavedLoss?, _):
                slots[owner] = nil
                save(track.workout(closingAt: date, endingBy: unsavedLoss), clock: clock)
            // A lost session saved its workout when it was lost; a reserved one never held a session.
            case .reserved, .lost:
                slots[owner] = nil
            case .ending, nil:
                break
        }
    }

    /// Ends every session and waits until HealthKit reports each one ended, so one that was still starting is ended
    /// again once it runs, and until every workout is saved. Termination's deadline bounds the wait.
    func endAll(at date: Date, clock: any Clock<Duration>) async {
        for owner in slots.keys {
            end(owner: owner, track: tracks[owner]?.track ?? WorkoutHealthTrack(), at: date, clock: clock)
        }
        let ending = slots.values.count(where: \.isEnding)
        let saves = saving.count
        if ending > 0 || saves > 0 {
            Logger.workoutHealth.notice("Waiting for \(ending, privacy: .public) workout sessions to end and \(saves, privacy: .public) workouts to save")
        }
        while isWaitedFor, !Task.isCancelled {
            let (stream, waiter) = AsyncStream<Void>.makeStream()
            endingWaiters.append(waiter)
            for await _ in stream {}
        }
    }

    /// Ends a session an earlier process left running, then lets the starts that waited for it go on. Runs once per
    /// process.
    func endOrphans(clock: any Clock<Duration>) async {
        guard !hasRecovered else { return }

        hasRecovered = true
        guard transport.canHoldSessions() else { return }

        isRecovering = true
        do {
            if let recovered = try await transport.recover() {
                await endIfOrphan(recovered, clock: clock)
            }
        } catch is CancellationError {
            // Not a failure; the waiting starts below still go on.
        } catch {
            Logger.workoutHealth.error("Recovering a workout session failed: \(String(reflecting: error), privacy: .public)")
        }
        isRecovering = false
        for waiter in recoveryWaiters {
            waiter.finish()
        }
        recoveryWaiters = []
    }

    private func canStart(_ owner: UUID) -> Bool {
        !gate.isClosed && !ended.contains(owner) && slots[owner] == nil
    }

    private func admit(_ owner: UUID, at date: Date, clock: any Clock<Duration>) {
        guard transport.canHoldSessions() else { return }

        let handle: SessionHandle
        do {
            handle = try transport.create()
        } catch {
            Logger.workoutHealth.error("Creating a workout session failed: \(String(reflecting: error), privacy: .public)")
            return
        }

        sessionCount += 1
        let number = sessionCount
        let events = handle.observe()
        // Delegate callbacks arrive for as long as the session lives, outside any caller of this actor.
        // swiftlint:disable:next no_unstructured_task
        let watch = Task { [weak self] in
            for await event in events {
                await self?.handle(event, of: number, owner: owner)
            }
        }
        slots[owner] = .starting(HeldSession(handle: handle, number: number, watch: watch, startDate: date, clock: clock))
        handle.start(date)
    }

    private func handle(_ event: SessionEvent, of number: Int, owner: UUID) {
        guard let slot = slots[owner], let held = slot.held, held.number == number else { return }

        switch (event, slot) {
            case (.changed(.running, _), .starting):
                slots[owner] = .running(held)
            case (.changed(.running, _), .ending):
                Logger.workoutHealth.notice("A workout session asked to end while starting ran; ending it again")
                held.handle.stop(max(now(), held.startDate))
                held.handle.end()
            case (.changed(.ended, _), .ending):
                slots[owner] = nil
                release(held)
            case (.changed(.ended, _), .starting):
                Logger.workoutHealth.notice("A workout session ended before it ran")
                slots[owner] = nil
                release(held)
            case let (.changed(.ended, date), .running):
                Logger.workoutHealth.error("HealthKit ended a running workout session")
                lose(held, owner: owner, at: date)
            case let (.changed(.stopped, date), .running):
                // Stopped, the session would keep the process alive until it ends.
                Logger.workoutHealth.error("HealthKit stopped a running workout session")
                held.handle.end()
                lose(held, owner: owner, at: date)
            case let (.failed(error), .starting):
                // A failed session may still be running; ending it leaves nothing behind.
                held.handle.end()
                slots[owner] = nil
                release(held)
                startFailed(error)
            case let (.failed(error), .running):
                if (error as? HKError)?.code == .errorAnotherWorkoutSessionStarted {
                    Logger.workoutHealth.notice("Another workout session took over")
                } else {
                    Logger.workoutHealth.error("A running workout session failed: \(String(reflecting: error), privacy: .public)")
                }
                held.handle.end()
                // A failure carries no date.
                lose(held, owner: owner, at: now())
            case let (.failed(error), .ending):
                Logger.workoutHealth.error("A workout session failed while ending: \(String(reflecting: error), privacy: .public)")
                slots[owner] = nil
                release(held)
            case (.changed, _), (.failed, _):
                break
        }
    }

    /// Only the next start, on the next active scene, tries again: a newer session ends the one running, ours or another
    /// app's, so retrying at once would take it from whoever started it.
    private func startFailed(_ error: any Error) {
        switch (error as? HKError)?.code {
            case .errorAnotherWorkoutSessionStarted:
                Logger.workoutHealth.notice("Another workout session started before this one ran")
            case .errorBackgroundWorkoutSessionNotAllowed:
                Logger.workoutHealth.notice("A workout session cannot start in the background")
            default:
                Logger.workoutHealth.error("Starting a workout session failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    /// A session HealthKit never reports ended stays held; the log is the only sign of it.
    private func watchEnd(of number: Int, owner: UUID, clock: any Clock<Duration>) {
        // The check must outlive the caller, which returns as soon as it has asked the session to end.
        // swiftlint:disable:next no_unstructured_task
        Task { [weak self] in
            do {
                try await clock.sleep(for: Self.endTimeout)
            } catch is CancellationError {
                return
            } catch {
                Logger.workoutHealth.error("Waiting for a workout session's end failed: \(String(reflecting: error), privacy: .public)")
                return
            }
            await self?.reportUnfinishedEnd(of: number, owner: owner)
        }
    }

    private func reportUnfinishedEnd(of number: Int, owner: UUID) {
        guard case let .ending(held) = slots[owner], held.number == number else { return }

        Logger.workoutHealth.notice("A workout session did not report its end within \(Self.endTimeout, privacy: .public)")
    }

    private func release(_ held: HeldSession) {
        held.handle.release()
        held.watch.cancel()
        wakeEndingWaiters()
    }

    /// Never started again, so the workout so far is saved now, up to `date`, when the session was lost. The track is
    /// projected onto the present, so a transition the timer sent after `date` does not read as the clock going back.
    private func lose(_ held: HeldSession, owner: UUID, at date: Date) {
        if let track = tracks.removeValue(forKey: owner)?.track {
            slots[owner] = .lost(unsavedLoss: nil, clock: held.clock)
            save(track.workout(closingAt: now(), endingBy: date), clock: held.clock)
        } else {
            slots[owner] = .lost(unsavedLoss: date, clock: held.clock)
        }
        release(held)
    }

    /// Saves beside the session, which the save does not need, so ending the session never waits for Health.
    private func save(_ workout: HealthWorkout?, clock: any Clock<Duration>) {
        guard let workout else { return }

        saveCount += 1
        let number = saveCount
        saving.insert(number)
        let transport = transport
        // The save must outlive the caller, which never waits for Health.
        // swiftlint:disable:next no_unstructured_task
        Task { [weak self] in
            do {
                let duration = try await clock.measure { try await transport.save(workout) }
                Logger.workoutHealth.notice("Saved a workout to Health in \(duration, privacy: .public)")
            } catch is CancellationError {
                // Nothing cancels a save; HealthKit reporting one is not a failure of ours.
            } catch {
                Logger.workoutHealth.error("Saving a workout to Health failed: \(String(reflecting: error), privacy: .public)")
            }
            await self?.saveFinished(number)
        }
    }

    private func saveFinished(_ number: Int) {
        saving.remove(number)
        wakeEndingWaiters()
    }

    private var isWaitedFor: Bool {
        slots.values.contains(where: \.isEnding) || !saving.isEmpty
    }

    private func wakeEndingWaiters() {
        guard !isWaitedFor else { return }

        for waiter in endingWaiters {
            waiter.finish()
        }
        endingWaiters = []
    }

    private func endIfOrphan(_ recovered: SessionHandle, clock: any Clock<Duration>) async {
        // A start that stopped waiting for recovery may own the very session recovery returns, possibly as another
        // object; only another process's session is ended.
        let activityID = recovered.activityID()
        guard !slots.values.contains(where: { $0.held?.handle.activityID() == activityID }) else {
            Logger.workoutHealth.notice("Recovery returned a workout session of this process")
            return
        }

        let events = recovered.observe()
        recovered.end()
        Logger.workoutHealth.notice("Ended a workout session left by an earlier process")
        let didEnd = await Self.finishes(within: Self.recoveryTimeout, clock: clock) {
            for await event in events {
                if case .changed(.ended, _) = event { return }
            }
        }
        if !didEnd {
            Logger.workoutHealth.notice("A workout session left by an earlier process did not report its end in time")
        }
        recovered.release()
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
