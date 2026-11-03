import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity
import WorkoutDomain

extension WorkoutTimerFeature {
    /// The commands of the card and the watch: one generation they are fenced by, and at most one pending command.
    struct ActivityControlState: Equatable, Sendable {
        /// The card's subscription is ready; the watch's commands do not need it.
        var isReady = false
        var isEnding = false
        /// The card's subscription was started; the watch may create this state first.
        var isActivitySubscribed = false
        var generation = 0
        var pending: PendingActivityControl?
    }

    /// Where a command came from, with the ID its source answers by; the two sources number independently.
    enum ControlSource: Equatable, Sendable {
        case liveActivity(requestID: Int)
        case watch(requestID: Int)
    }

    /// A command refused on arrival, answered once the pass has settled the generation its source should see.
    struct ControlRefusal: Equatable, Sendable {
        let source: ControlSource
        let result: LiveActivityControlResult
    }

    struct PendingActivityControl: Equatable, Sendable {
        let source: ControlSource
        let result: LiveActivityControlResult
        /// When it was admitted, on `continuousClock`: past `stallLimit` it counts as stalled. The clock counts the time
        /// the app was suspended too (iOS 17–25), so a command held across a suspension counts as stalled at once on
        /// return; it only stops waiting sooner and refuses the next command as unavailable.
        let admittedAt: MonotonicInstant
        /// The watch's command scheduled its stall limit once it outlived the pass that admitted it.
        var isStallScheduled = false
        /// Its stall was logged, so a stuck drain logs once rather than per refused command.
        var isStallLogged = false
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
        if let source = Self.controlSource(of: action), state.activityControls?.pending?.source == source,
           state.activityControls?.pending?.result == .applied {
            changed = true
        }
        if changed { state.activityControls?.generation += 1 }
    }

    /// The command an action brings, by its source.
    private static func controlSource(of action: Action) -> ControlSource? {
        switch action {
            case let .internal(.activityRequestReceived(request)):
                .liveActivity(requestID: request.id)
            case let .internal(.watchRequestReceived(request)):
                if case .command = request.kind { .watch(requestID: request.id) } else { nil }
            default:
                nil
        }
    }

    /// Created by whichever subscription comes first, so the watch can command a timer whose card is not ready.
    func ensureControlState(_ state: inout State) {
        guard state.activityControls == nil else { return }
        state.activityControls = ActivityControlState(isEnding: state.isClosing)
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

    /// One rule for the card's and the watch's commands. The command is fenced by the generation the source saw, which
    /// is the one published before this pass: a stale card of a manual pause still resumes after `advance` reaches the
    /// pause. The rule then applies to the phase `advance` settled. A refusal is answered by `finishActivityControl`.
    func handleControl(
        _ command: LiveActivityCommand,
        generation: Int,
        from source: ControlSource,
        _ state: inout State,
        at now: Date
    ) -> Effect<Action> {
        let published = state.activityControls?.generation
        // Even a rejected request commits elapsed time and reconciles a moved wall clock.
        let mustSync = advance(&state, at: now)
        guard isReady(for: source, state) else {
            state.controlRefusal = ControlRefusal(source: source, result: .unavailable)
            return mustSync ? syncClock(&state, at: now) : .none
        }
        if let pending = state.activityControls?.pending {
            // A second command never runs while the first is held; once that one stalls, it is not worth retrying.
            let isStalled = isStalled(pending)
            if isStalled, !pending.isStallLogged {
                state.activityControls?.pending?.isStallLogged = true
                Self.logger.notice("A held command outlived its stall limit; later commands are unavailable until it ends")
            }
            state.controlRefusal = ControlRefusal(source: source, result: isStalled ? .unavailable : .busy)
            return mustSync ? syncClock(&state, at: now) : .none
        }

        var result = LiveActivityControlResult.stale
        if generation == published {
            switch (command, state.snapshot.status) {
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
        state.activityControls?.pending = PendingActivityControl(
            source: source,
            result: result,
            admittedAt: MonotonicInstant(now: clock)
        )
        return result == .applied || mustSync ? syncClock(&state, at: now) : .none
    }

    /// The card's commands need its subscription; the watch's need only a started clock and an open screen.
    private func isReady(for source: ControlSource, _ state: State) -> Bool {
        switch source {
            case .liveActivity:
                state.activityControls?.isReady == true && state.activityControls?.isEnding == false
            case .watch:
                !state.isClosing && state.clockGeneration > 0 && state.activityControls?.isEnding == false
        }
    }

    func isStalled(_ pending: PendingActivityControl) -> Bool {
        // A reading of another clock cannot be measured; it counts as stalled rather than holding commands forever.
        guard let held = pending.admittedAt.duration(toNowOf: clock) else { return true }
        return held >= LiveActivityControlTiming.stallLimit
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

    /// The single place a command is answered, after the pass settled the generation and the syncs ran. The card's
    /// command waits for its drain and the notifications, as CT-4 requires. The watch's command gets its own result:
    /// a card that is off, swiped away or not syncing does not change what the timer did. Past the stall limit the
    /// watch's command stops waiting for the notifications and is dropped without an answer once its drain is done;
    /// the link already answered the watch that it does not know.
    func finishActivityControl(_ state: inout State, publication: WatchRunPublication?) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        if let refusal = state.controlRefusal {
            state.controlRefusal = nil
            effects.append(acknowledgeControl(refusal.source, result: refusal.result, state, publication: publication))
        }
        guard var pending = state.activityControls?.pending else { return .merge(effects) }

        pending.notificationRevision = state.notifications.revision
        let isWatch = if case .watch = pending.source { true } else { false }
        if isWatch, pending.activityResult == nil, pending.activityRevision == 0, !state.syncsLiveActivity {
            // No drain was started for it: the card cannot be shown or is not subscribed. A drain already started,
            // also one whose subscription ended since, still answers and is waited for. `activityRevision` is set by
            // `syncLiveActivity`, which the second reducer runs before this in the same pass; keep that order.
            pending.activityResult = .unavailable
        }
        let isStalledWatch = isWatch && isStalled(pending)
        guard pending.activityResult != nil,
              isStalledWatch || state.notifications.completedRevision >= pending.notificationRevision else {
            guard case .watch = pending.source, !pending.isStallScheduled else {
                state.activityControls?.pending = pending
                return .merge(effects)
            }
            // The watch's command outlived its pass: it stops waiting after the limit even if nothing else happens.
            pending.isStallScheduled = true
            state.activityControls?.pending = pending
            let limit = pending.admittedAt.duration(toNowOf: clock).map { LiveActivityControlTiming.stallLimit - $0 }
            effects.append(
                .run { [clock] send in
                    try await clock.sleep(for: max(.zero, limit ?? .zero))
                    await send(.internal(.watchCommandStallLimitReached))
                }
                .cancellable(id: CancelID.controlStall, cancelInFlight: true)
            )
            return .merge(effects)
        }

        state.activityControls?.pending = nil
        effects.append(.cancel(id: CancelID.controlStall))
        if isStalledWatch {
            Self.logger.notice("A command from the watch outlived its stall limit; it is released without an answer")
            return .merge(effects)
        }
        // A partial notification failure is already visible in its footnote. The command remains
        // applied, so asking the user to retry it could undo their Pause/Resume.
        let result = switch pending.source {
            case .liveActivity:
                pending.activityResult == .applied ? pending.result : pending.activityResult ?? pending.result
            case .watch:
                pending.result
        }
        effects.append(acknowledgeControl(pending.source, result: result, state, publication: publication))
        return .merge(effects)
    }

    /// Answers only the command's own source; the watch also gets the run this pass published.
    func acknowledgeControl(
        _ source: ControlSource,
        result: LiveActivityControlResult,
        _ state: State,
        publication: WatchRunPublication?
    ) -> Effect<Action> {
        switch source {
            case let .liveActivity(requestID):
                return .run { [liveActivity, owner = state.id] _ in
                    await liveActivity.requestHandled(owner, requestID, result)
                }
            case let .watch(requestID):
                return .run { [watchCompanion, owner = state.id] _ in
                    await watchCompanion.controlHandled(owner, requestID, result, publication)
                }
        }
    }
}

extension WorkoutTimerFeature.State {
    /// Whether this pass sends the card a sync a pending command can wait for.
    var syncsLiveActivity: Bool {
        clockGeneration > 0 && activityControls?.isReady == true && activityControls?.isEnding == false
    }
}
