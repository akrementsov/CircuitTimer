import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity

extension WorkoutTimerFeature.State {
    /// Lets the watch control this timer, or stops it: only the screen's owner calls it, from the full version.
    public mutating func setWatchControl(_ isAllowed: Bool) {
        allowsWatchControl = isAllowed
    }
}

extension WorkoutTimerFeature {
    /// Runs after every action, like the Live Activity's sync: the watch link drops a run it already published. A
    /// request from the watch is answered with the run settled for it, which the link numbers before it replies.
    func syncWatch(_ state: State, after action: Action, publication: WatchRunPublication?) -> Effect<Action> {
        // A command is answered with its result by `finishActivityControl`; this pass publishes as usual.
        if case let .internal(.watchRequestReceived(request)) = action, case .refresh = request.kind {
            // Without the full version the reply confirms no run.
            let answer = state.allowsWatchControl ? publication : nil
            return .run { [watchCompanion, id = state.id] _ in
                await watchCompanion.refreshHandled(id, request.id, answer)
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

    /// The run as this pass publishes it, once: the watch's ack carries the same publication. `nil` before the clock
    /// started and while closing.
    func watchPublication(_ state: State, at now: Date) -> WatchRunPublication? {
        guard state.clockGeneration > 0, !state.isClosing else { return nil }
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
