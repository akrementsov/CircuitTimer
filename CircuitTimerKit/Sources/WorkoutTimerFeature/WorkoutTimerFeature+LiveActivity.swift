import ComposableArchitecture
import Foundation
import WorkoutActivity

extension WorkoutTimerFeature {
    /// Runs after every action: the coordinator drops content it already shows, and a stage change on a tick reaches
    /// the Lock Screen without restarting the clock. Failures and their state live in the coordinator; the screen
    /// learns only whether to warn.
    func syncLiveActivity(_ state: inout State, after action: Action, at now: Date) -> Effect<Action> {
        if case .internal(.liveActivityNoticeChanged) = action { return .none }
        if case .internal(.activitySynchronized) = action { return .none }
        guard state.clockGeneration > 0, state.activityControls?.isReady == true,
              state.activityControls?.isEnding == false else { return .none }

        let attributes = WorkoutActivityAttributes(workoutName: state.workoutName)
        let content = WorkoutActivityAttributes.ContentState(
            run: state.run, at: now, controlGeneration: state.activityControls?.generation ?? 0
        )
        let revision = liveActivity.nextRevision()
        if state.activityControls?.pending != nil, state.activityControls?.pending?.activityResult == nil {
            state.activityControls?.pending?.activityRevision = revision
            return .run { [liveActivity, id = state.id] send in
                let result = await liveActivity.syncWithResult(id, revision, attributes, content)
                guard !Task.isCancelled else { return }
                await send(.internal(.activitySynchronized(revision: revision, result)))
            }
        }
        return .run { [liveActivity, id = state.id] send in
            guard let notice = await liveActivity.sync(id, revision, attributes, content) else { return }

            await send(.internal(.liveActivityNoticeChanged(notice)))
        }
    }

    /// Results can arrive in any order; a notice older than the shown one changes nothing.
    func liveActivityNoticeChanged(_ notice: LiveActivityNotice, _ state: inout State) {
        guard notice.serial > (state.liveActivityNotice?.serial ?? 0) else { return }

        state.liveActivityNotice = notice
    }
}

extension WorkoutTimerFeature.State {
    /// Whether the screen warns that the Lock Screen cannot show the workout.
    var isLiveActivityFailing: Bool {
        liveActivityNotice?.isFailing == true
    }
}
