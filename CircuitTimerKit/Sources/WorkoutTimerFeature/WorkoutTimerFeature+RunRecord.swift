import ComposableArchitecture
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

        let revision = runRecord.nextRevision()
        state.recordSync = .pending(revision: revision, record: record)
        return .run { [runRecord, sessionID = state.sceneSessionID] send in
            do {
                try await runRecord.write(record, sessionID, revision)
                await send(.internal(.recordWritten(revision: revision, succeeded: true)))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Saving the run failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.recordWritten(revision: revision, succeeded: false)))
            }
        }
    }

    /// Only the newest write decides what the file holds and whether the screen warns.
    func recordWritten(revision: Int, succeeded: Bool, _ state: inout State) {
        guard case let .pending(pending, record) = state.recordSync, pending == revision else { return }

        state.recordSync = succeeded ? .stored(record) : .failed(record)
        state.hasRecordFailed = !succeeded
    }
}
