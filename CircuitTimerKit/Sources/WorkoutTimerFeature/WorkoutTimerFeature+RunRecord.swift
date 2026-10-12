import ComposableArchitecture
import os
import WorkoutDomain
import WorkoutStorage

extension WorkoutTimerFeature {
    /// What the record file holds, as far as the screen knows.
    enum RecordSync: Equatable, Sendable {
        /// The next sync writes whatever the run is. Nothing written yet, where the file may still hold a run an earlier
        /// clear failed to remove; or the file's date is due a refresh as the app leaves the screen.
        case unknown
        case pending(revision: Int, record: WorkoutRunRecord?)
        case stored(WorkoutRunRecord?)
        case failed(WorkoutRunRecord?)
    }

    /// Writes the record of the settled run, unless the file already holds it or is about to.
    ///
    /// A running record changes with every sync, as its anchor and position move together, so only a paused or
    /// waiting run is ever skipped. A failed record is written again with a new revision.
    ///
    /// Takes a background-task assertion before the effect is scheduled, so the write can finish if the app leaves
    /// the screen; the effect ends it. Always return the effect: a discarded one keeps the assertion until it expires.
    func persist(_ state: inout State) -> Effect<Action> {
        let record = WorkoutRunRecord(workoutID: state.workoutID, run: state.run)
        switch state.recordSync {
            case let .pending(_, pending) where pending == record:
                return .none
            case let .stored(stored) where stored == record:
                return .none
            case .unknown, .pending, .stored, .failed:
                break
        }

        let revision = workoutRunRecord.nextRevision()
        let token = backgroundTask.begin("Save the workout run")
        state.recordSync = .pending(revision: revision, record: record)
        return .run { [workoutRunRecord, backgroundTask] send in
            let succeeded: Bool
            do {
                try await workoutRunRecord.write(record, revision)
                succeeded = true
            } catch is CancellationError {
                await backgroundTask.end(token)
                return
            } catch {
                Self.logger.error("Saving the run failed: \(String(reflecting: error), privacy: .public)")
                succeeded = false
            }
            await backgroundTask.end(token)
            await send(.internal(.recordWritten(revision: revision, succeeded: succeeded)))
        }
    }

    /// Only the newest write decides what the file holds and whether the screen warns.
    ///
    /// A failed write leaves the file as it was: it may hold no run, or an earlier state of this one or of another run.
    /// The screen says so until a later sync writes again and succeeds.
    func recordWritten(revision: Int, succeeded: Bool, _ state: inout State) {
        guard case let .pending(pending, record) = state.recordSync, pending == revision else { return }

        state.recordSync = succeeded ? .stored(record) : .failed(record)
        state.hasRecordFailed = !succeeded
    }
}
