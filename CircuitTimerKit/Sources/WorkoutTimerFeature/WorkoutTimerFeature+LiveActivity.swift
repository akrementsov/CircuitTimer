import ComposableArchitecture
import Foundation
import WorkoutActivity

extension WorkoutTimerFeature {
    /// Runs after every action: the coordinator drops content it already shows, and a stage change on a tick reaches
    /// the Lock Screen without restarting the clock. Failures and their state live in the coordinator; the screen
    /// learns only whether to warn.
    func syncLiveActivity(_ state: State, after action: Action, at now: Date) -> Effect<Action> {
        if case .internal(.liveActivityNoticeChanged) = action { return .none }
        guard state.clockGeneration > 0 else { return .none }

        let attributes = WorkoutActivityAttributes(workoutName: state.workoutName)
        let content = WorkoutActivityAttributes.ContentState(run: state.run, at: now)
        let revision = liveActivity.nextRevision()
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
