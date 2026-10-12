import ComposableArchitecture
import Foundation
import os
import WorkoutDomain
import WorkoutStorage
import WorkoutTimerFeature

extension AppFeature {
    /// The launch's check for a run saved before the process was gone. It ends before the first list is shown, so no
    /// row, screen or write exists yet when a restored timer opens.
    enum RunRestore: Equatable, Sendable {
        case idle
        /// Reading the record; the list waits.
        case reading
        /// Found; decided once the workouts are loaded.
        case found(StoredRunRecord)
        case resolved
    }

    /// Why the saved run could not be read. The file stays, except a corrupt one.
    public enum RunRecordLoadFailure: Equatable, Sendable {
        case unreadable
        case corrupt
        case unsupportedSchema
    }

    /// How long the list waits for the record before it gives up on restoring.
    static let recordReadTimeout: Duration = .seconds(2)
    /// A run left paused or waiting this long was abandoned, not interrupted.
    static let restoreAgeLimit: Duration = .seconds(24 * 60 * 60)

    /// Reads the saved run. The read and its timeout race as two effects: the file read cannot be interrupted, and
    /// whichever answers first while reading decides.
    func readRunRecord(_ state: inout State) -> Effect<Action> {
        state.runRestore = .reading
        let read = Effect<Action>.run { [workoutRunRecord] send in
            do {
                await send(.internal(.runRecordLoaded(try await workoutRunRecord.load())))
            } catch is CancellationError {
                return
            } catch where Task.isCancelled {
                // A result after the timeout decides nothing and is not reported as a failure.
                return
            } catch RunRecordError.unsupportedSchema(let version) {
                Self.logger.notice("The saved run was written by another app version (schema \(version)); it stays on disk")
                await send(.internal(.runRecordLoadingFailed(.unsupportedSchema)))
            } catch RunRecordError.corrupt(let error) {
                Self.logger.error("The saved run is corrupt: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.runRecordLoadingFailed(.corrupt)))
            } catch {
                Self.logger.error("Reading the saved run failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.runRecordLoadingFailed(.unreadable)))
            }
        }
        .cancellable(id: CancelID.readRunRecord)
        let timeout = Effect<Action>.run { [clock] send in
            do {
                try await clock.sleep(for: Self.recordReadTimeout)
                await send(.internal(.runRecordReadTimedOut))
            } catch is CancellationError {
                return
            } catch {
                // The read still decides; only the bound on the wait is lost.
                Self.logger.error("The saved run's timeout failed: \(String(reflecting: error), privacy: .public)")
            }
        }
        .cancellable(id: CancelID.readRunRecordTimeout)
        return .merge(read, timeout)
    }

    func runRecordLoaded(_ stored: StoredRunRecord?, _ state: inout State) -> Effect<Action> {
        guard state.runRestore == .reading else { return .none }

        let stopTimeout = Effect<Action>.cancel(id: CancelID.readRunRecordTimeout)
        guard let stored else {
            state.runRestore = .resolved
            return .merge(stopTimeout, loadWorkouts(&state))
        }

        state.runRestore = .found(stored)
        return .merge(stopTimeout, loadWorkouts(&state))
    }

    /// The file exists but cannot be used: the run would have come back, so the user is told.
    func runRecordLoadingFailed(_ failure: RunRecordLoadFailure, _ state: inout State) -> Effect<Action> {
        guard state.runRestore == .reading else { return .none }

        state.runRestore = .resolved
        state.destination = .alert(.runNotRestored)
        // An unreadable or newer file is kept for the next launch; a new timer's first write replaces it.
        let discard = failure == .corrupt ? discardRunRecord() : .none
        return .merge(.cancel(id: CancelID.readRunRecordTimeout), discard, loadWorkouts(&state))
    }

    /// The read stalled before the app could tell whether a file exists. Rare enough to accept the alert
    /// even when there is none; the file, if any, is kept for the next launch.
    func runRecordReadTimedOut(_ state: inout State) -> Effect<Action> {
        guard state.runRestore == .reading else { return .none }

        Self.logger.error("Reading the saved run timed out; it stays for the next launch")
        state.runRestore = .resolved
        state.destination = .alert(.runNotRestored)
        return .merge(.cancel(id: CancelID.readRunRecord), loadWorkouts(&state))
    }

    /// Reopens the found run over the loaded list, or drops it. Runs once, at the first load.
    func resolveRestore(_ state: inout State) -> Effect<Action> {
        guard case let .found(stored) = state.runRestore, case let .loaded(workouts) = state.workouts else { return .none }

        state.runRestore = .resolved
        let record = stored.record
        let now = date()
        let age = now.elapsed(since: stored.savedAt)
        // An old pause is dropped before its workout is looked up: an abandoned run is no error, even if the workout is
        // gone by now.
        if record.phase != .running, age > Self.restoreAgeLimit {
            return discardRunRecord()
        }
        guard let workout = workouts[id: record.workoutID] else {
            Self.logger.notice("The saved run's workout is gone; dropping the run")
            state.destination = .alert(.runNotRestored)
            return discardRunRecord()
        }

        let run: WorkoutRun
        do {
            run = try WorkoutRun(schedule: WorkoutSchedule(workout: workout), restoring: record, at: now)
        } catch {
            Self.logger.notice("The saved run no longer fits its workout: \(String(reflecting: error), privacy: .public)")
            state.destination = .alert(.runNotRestored)
            return discardRunRecord()
        }
        if let since = record.since, since > now {
            Self.logger.notice("The clock went back while the app was closed; the run continues from its saved position")
        }
        switch run.phase {
            case .idle, .finished:
                // It ended while the app was closed: nothing is left to show.
                return discardRunRecord()
            case .paused, .awaitingUser:
                // A run that kept going into a manual pause long ago was abandoned there too.
                guard age <= Self.restoreAgeLimit else { return discardRunRecord() }
            case .running:
                break
        }
        guard state.destination == nil else {
            Self.logger.error("Refused to restore a run over another presentation; it stays for the next launch")
            return .none
        }

        state.selectedTab = .workouts
        state.destination = .timer(restoredTimerState(for: workout, run: run, at: now))
        return .none
    }

    /// Clears the saved run. Like every record write, it holds a background-task assertion taken here, before the
    /// effect is scheduled.
    func discardRunRecord() -> Effect<Action> {
        let revision = workoutRunRecord.nextRevision()
        let token = backgroundTask.begin("Clear the saved workout run")
        return .run { [workoutRunRecord, backgroundTask] _ in
            do {
                try await workoutRunRecord.write(nil, revision)
            } catch is CancellationError {
                // Only the root store going away cancels it; the write has run regardless.
                await backgroundTask.end(token)
                return
            } catch {
                Self.logger.error("Clearing the saved run failed: \(String(reflecting: error), privacy: .public)")
            }
            await backgroundTask.end(token)
        }
    }
}

extension AlertState where Action == Never {
    static var runNotRestored: Self {
        AlertState {
            TextState("workouts.restoreFailed.title", bundle: .module)
        } message: {
            TextState("workouts.restoreFailed.message", bundle: .module)
        }
    }
}
