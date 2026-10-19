import ComposableArchitecture
import Foundation
import WorkoutActivity
import WorkoutDomain

extension WorkoutTimerFeature {
    struct ActivityControlState: Equatable, Sendable {
        var isReady = false
        var isEnding = false
        var generation = 0
        var pending: PendingActivityControl?
    }

    struct PendingActivityControl: Equatable, Sendable {
        let id: Int
        let result: LiveActivityControlResult
        var activityRevision = 0
        var activityResult: LiveActivityControlResult?
        var notificationRevision = 0
    }

    struct ControlMoment {
        let status: WorkoutRun.Snapshot.Status
        let stageIndex: Int?
        let countdown: Countdown.Purpose?
        let clockGeneration: Int

        init(_ state: State) {
            status = state.snapshot.status
            stageIndex = state.snapshot.currentStage?.index
            countdown = state.countdown?.purpose
            clockGeneration = state.clockGeneration
        }
    }

    /// Control phases, rather than clock-loop replacements, invalidate rendered commands. This
    /// includes automatic resume and entry into a later manual pause; ordinary stage ticks do not.
    func updateControlGeneration(_ state: inout State, after action: Action, from before: ControlMoment) {
        guard state.activityControls?.isEnding == false else { return }

        var changed = state.snapshot.status != before.status || state.countdown?.purpose != before.countdown
        if action == .view(.nextButtonTapped) {
            changed = changed || state.snapshot.currentStage?.index != before.stageIndex
        }
        if case let .internal(.clockFailed(generation)) = action, generation == before.clockGeneration {
            changed = true
        }
        if case .internal(.activityRequestReceived) = action, state.activityControls?.pending?.result == .applied {
            changed = true
        }
        if changed { state.activityControls?.generation += 1 }
    }

    func subscribeActivityRequests(_ owner: UUID) -> Effect<Action> {
        .run { [liveActivity] send in
            let requests = await liveActivity.requests(owner)
            guard !Task.isCancelled else { return }
            await send(.internal(.activityRequestsReady))
            for await request in requests {
                await send(.internal(.activityRequestReceived(request)))
            }
            if !Task.isCancelled { await send(.internal(.activityRequestsEnded)) }
        }
        .cancellable(id: CancelID.activityRequests, cancelInFlight: true)
    }

    func handleActivityRequest(_ request: LiveActivityControlRequest, _ state: inout State, at now: Date) -> Effect<Action> {
        let ready = state.activityControls?.isReady == true && state.activityControls?.isEnding == false
        let matches = request.generation == state.activityControls?.generation
        // Even a rejected request commits elapsed time and reconciles a moved wall clock.
        let mustSync = advance(&state, at: now)
        guard ready else {
            let settled: Effect<Action> = mustSync ? syncClock(&state, at: now) : .none
            return .merge(settled, acknowledgeActivityRequest(state.id, requestID: request.id, result: .unavailable))
        }
        guard state.activityControls?.pending == nil else {
            let settled: Effect<Action> = mustSync ? syncClock(&state, at: now) : .none
            return .merge(settled, acknowledgeActivityRequest(state.id, requestID: request.id, result: .busy))
        }

        var result = LiveActivityControlResult.stale
        if matches {
            switch (request.command, state.snapshot.status) {
                case (.pause, .running) where state.countdown == nil:
                    state.run.pause(at: now)
                    result = .applied
                case (.resume, .paused), (.resume, .awaitingUser):
                    state.countdown = nil
                    state.destination = nil
                    state.path.removeAll()
                    state.run.resume(at: now)
                    result = .applied
                default:
                    break
            }
        }
        state.activityControls?.pending = PendingActivityControl(id: request.id, result: result)
        return result == .applied || mustSync ? syncClock(&state, at: now) : .none
    }

    func activitySynchronized(revision: Int, result: LiveActivitySyncResult, _ state: inout State) {
        if let notice = result.notice { liveActivityNoticeChanged(notice, &state) }
        guard revision == state.activityControls?.pending?.activityRevision else { return }

        switch result.outcome {
            case .applied:
                state.activityControls?.pending?.activityResult = .applied
            case .unavailable:
                state.activityControls?.pending?.activityResult = .unavailable
            case .deferred, .failed:
                state.activityControls?.pending?.activityResult = .failed
            case .superseded:
                // A newer sync carries the already-applied command; its result settles the wait.
                break
        }
    }

    func finishActivityControl(_ state: inout State) -> Effect<Action> {
        guard var pending = state.activityControls?.pending else { return .none }

        pending.notificationRevision = state.notifications.revision
        state.activityControls?.pending = pending
        guard let activityResult = pending.activityResult,
              state.notifications.completedRevision >= pending.notificationRevision else { return .none }

        state.activityControls?.pending = nil
        // A partial notification failure is already visible in its footnote. The command remains
        // applied, so asking the user to retry it could undo their Pause/Resume.
        let result = activityResult == .applied ? pending.result : activityResult
        return acknowledgeActivityRequest(state.id, requestID: pending.id, result: result)
    }

    func acknowledgeActivityRequest(_ owner: UUID, requestID: Int, result: LiveActivityControlResult) -> Effect<Action> {
        .run { [liveActivity] _ in await liveActivity.requestHandled(owner, requestID, result) }
    }
}
