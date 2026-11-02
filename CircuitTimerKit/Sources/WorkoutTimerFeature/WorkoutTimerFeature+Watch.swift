import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity

extension WorkoutTimerFeature {
    /// Runs after every action, like the Live Activity's sync: the watch link drops a run it already published. A
    /// request from the watch is answered with the run settled for it, which the link numbers before it replies.
    func syncWatch(_ state: inout State, after action: Action, at now: Date) -> Effect<Action> {
        let canPublish = state.clockGeneration > 0 && !state.isClosing
        let publication = canPublish ? watchPublication(state, at: now) : nil
        if case let .internal(.watchRequestReceived(request)) = action {
            return .run { [watchCompanion, id = state.id] _ in
                switch request.kind {
                    case .refresh:
                        await watchCompanion.refreshHandled(id, request.id, publication)
                    case .command:
                        // The timer applies no command from the watch yet.
                        await watchCompanion.controlHandled(id, request.id, .unavailable, publication)
                }
            }
        }
        guard let publication else { return .none }
        return .run { [watchCompanion] _ in
            await watchCompanion.publishRun(publication.revision, publication.run)
        }
    }

    /// The watch's requests for this timer. The subscription belongs to the stack, like the Live Activity's.
    func subscribeWatchRequests(_ owner: UUID) -> Effect<Action> {
        .run { [watchCompanion] send in
            for await request in await watchCompanion.controlRequests(owner) {
                await send(.internal(.watchRequestReceived(request)))
            }
        }
        .cancellable(id: CancelID.watchRequests, cancelInFlight: true)
    }

    private func watchPublication(_ state: State, at now: Date) -> WatchRunPublication {
        let run = WatchRun(
            owner: state.id,
            attributes: WorkoutActivityAttributes(workoutName: state.workoutName),
            content: WorkoutActivityAttributes.ContentState(
                run: state.run, at: now, controlGeneration: state.activityControls?.generation ?? 0
            )
        )
        return WatchRunPublication(revision: watchCompanion.nextRevision(), run: run)
    }
}
