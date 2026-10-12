import ComposableArchitecture
import os
import WorkoutDomain
import WorkoutStorage

extension WorkoutTimerFeature {
    /// What the record file holds, as far as the screen knows.
    enum RecordSync: Equatable, Sendable {
        /// Nothing written yet. The file may still hold a run an earlier clear failed to remove, so the first sync
        /// writes even a run that has no record.
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
        return .run { [workoutRunRecord, backgroundTask, sessionID = state.sceneSessionID] send in
            let succeeded: Bool?
            do {
                try await workoutRunRecord.write(record, sessionID, revision)
                succeeded = true
            } catch is CancellationError {
                succeeded = nil
            } catch {
                Self.logger.error("Saving the run failed: \(String(reflecting: error), privacy: .public)")
                succeeded = false
            }
            await backgroundTask.end(token)
            if let succeeded {
                await send(.internal(.recordWritten(revision: revision, succeeded: succeeded)))
            }
        }
    }

    /// Only the newest write decides what the file holds and whether the screen warns.
    func recordWritten(revision: Int, succeeded: Bool, _ state: inout State) {
        guard case let .pending(pending, record) = state.recordSync, pending == revision else { return }

        state.recordSync = succeeded ? .stored(record) : .failed(record)
        // Only a run that could have come back is lost; a failed clear is logged, and the file removes an outdated
        // record when a newer one fails to replace it.
        state.hasRecordFailed = !succeeded && record != nil
    }
}
