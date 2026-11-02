import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// The iPhone's running workout on the watch. Its clock counts on the watch only under a lease: a reply from the
/// run's own timer, at most `confirmationLease` after the request was sent, renewed every `leaseRenewal`. A context or
/// a message shows the run and carries a live lease on to its newer content, but never opens or extends one.
extension WatchRemoteFeature {
    static let confirmationLease: Duration = .seconds(10)
    static let leaseRenewal: Duration = .seconds(5)

    struct ShownRun: Equatable, Sendable {
        let run: WatchRun
        /// The last accepted state said the run's timer is open.
        var isLive: Bool
        /// The running stage ended with no newer content: its digits are gone until the iPhone confirms the next.
        var isStageOver = false
    }

    /// The confirmation the digits count under.
    struct Lease: Equatable, Sendable {
        /// The request whose reply opened it.
        let serial: Int
        /// When that request was sent; it decides the lease's end.
        let sentAt: MonotonicInstant
        /// When the lease opened, in wall time: the screen's timeline starts there. A wall clock moved back moves it
        /// back too, so the timeline's first entry is never in the future.
        var openedAt: Date
        /// The lease's end in wall time, only for the screen to hide the digits on its own; every action computes it
        /// again from `sentAt`, so a wall clock moved meanwhile moves it back where it belongs.
        var deadline: Date
    }

    /// Whether the watch asks the iPhone about its run: the run's screen shows, its timer can still change, and the
    /// iPhone can answer. A lowered wrist stops the renewal; the lease runs out by itself.
    func needsRenewal(_ state: State) -> Bool {
        guard let shown = state.run, !state.isRunTooLarge else { return false }
        if case .incompatible = state.problem { return false }
        if case .finished = shown.run.content.phase { return false }
        return state.isSceneActive && !state.isLuminanceReduced && state.link?.canSend == true
    }

    /// The one way a reason about the run asks: absorbed by a request in flight, whose reply settles the run anyway,
    /// and by a scheduled retry, which no new reason may hurry.
    func askForRun(_ state: inout State) -> Effect<Action> {
        guard needsRenewal(state), state.refresh.inFlight == nil, !state.refresh.isRetryScheduled else { return .none }
        return requestRefresh(&state)
    }

    /// Drops a lease whose time ran out and moves a live lease's wall-clock end to what the monotonic clock vouches
    /// for: every action starts with it, so a late `leaseExpired` or a moved wall clock never shows digits.
    func dropExpiredLease(_ state: inout State) {
        guard let lease = state.lease else { return }
        guard let elapsed = lease.sentAt.duration(toNowOf: clock), elapsed < Self.confirmationLease else {
            state.lease = nil
            return
        }
        let now = date()
        state.lease?.deadline = now.adding(Self.confirmationLease - elapsed)
        state.lease?.openedAt = min(lease.openedAt, now)
    }

    /// Takes the run of an accepted state. A newer state without a live timer, or with another owner's run, revokes
    /// the lease; the same owner's newer content keeps it.
    func applyRun(_ phoneState: PhoneState, _ state: inout State) -> Effect<Action> {
        state.isRunTooLarge = phoneState.isRunTooLarge
        guard let run = phoneState.run else {
            state.run = nil
            state.lease = nil
            return .merge(.cancel(id: CancelID.stageEnd), .cancel(id: CancelID.lease))
        }
        if state.run?.run.owner != run.owner || !phoneState.isRunLive {
            state.lease = nil
        }
        guard state.run?.run != run else {
            state.run?.isLive = phoneState.isRunLive
            return .none
        }
        state.run = ShownRun(run: run, isLive: phoneState.isRunLive)
        return scheduleStageEnd(&state)
    }

    /// Hides the digits when the running stage ends, without an answer from the iPhone.
    func scheduleStageEnd(_ state: inout State) -> Effect<Action> {
        state.runGeneration += 1
        guard case let .running(running) = state.run?.run.content.phase else { return .cancel(id: CancelID.stageEnd) }
        let remaining = running.stageEnd.elapsed(since: date())
        guard remaining > .zero else {
            state.run?.isStageOver = true
            return .cancel(id: CancelID.stageEnd)
        }
        state.run?.isStageOver = false
        let generation = state.runGeneration
        return .run { [clock] send in
            try await clock.sleep(for: remaining)
            await send(.internal(.stageEnded(generation: generation)))
        }
        .cancellable(id: CancelID.stageEnd, cancelInFlight: true)
    }

    /// A set clock moves the stage's end in wall time: the wait for it is counted again from the new date, and a stage
    /// the move ended asks as its own end would.
    func systemClockChanged(_ state: inout State) -> Effect<Action> {
        guard let shown = state.run else { return .none }
        let stageEnd = scheduleStageEnd(&state)
        guard !shown.isStageOver, state.run?.isStageOver == true else { return stageEnd }
        return .merge(stageEnd, askForRun(&state))
    }

    /// Opens the lease from a confirming reply, counted from when its request was sent.
    func openLease(from request: RefreshRequest, _ state: inout State) -> Effect<Action> {
        guard let elapsed = request.sentAt.duration(toNowOf: clock), elapsed < Self.confirmationLease else { return .none }
        let remaining = Self.confirmationLease - elapsed
        let now = date()
        state.lease = Lease(serial: request.serial, sentAt: request.sentAt, openedAt: now, deadline: now.adding(remaining))
        return .run { [clock] send in
            try await clock.sleep(for: remaining)
            await send(.internal(.leaseExpired(serial: request.serial)))
        }
        .cancellable(id: CancelID.lease, cancelInFlight: true)
    }

    /// A reply that did not confirm the run while the watch needs it: the run's own retry, with the delays a failure
    /// takes, so an iPhone that keeps answering «not live» is not asked at once again.
    func scheduleRunRetry(_ state: inout State) -> Effect<Action> {
        state.refresh.failures += 1
        state.refresh.runRetryGeneration += 1
        state.refresh.isRetryScheduled = true
        let generation = state.refresh.runRetryGeneration
        let delay = Self.retryDelay(afterFailures: state.refresh.failures)
        return .merge(
            .cancel(id: CancelID.renewal),
            .run { [clock] send in
                try await clock.sleep(for: delay)
                await send(.internal(.runRetryDue(generation: generation)))
            }
            .cancellable(id: CancelID.runRetry, cancelInFlight: true)
        )
    }

    func reduceRun(into state: inout State, _ action: Action.Internal) -> Effect<Action> {
        switch action {
            case let .renewalDue(serial):
                guard serial == state.refresh.lastSerial else { return .none }
                if state.refresh.inFlight?.serial == serial {
                    // The request is slow: its confirming reply asks again at once.
                    state.refresh.isRenewalDue = needsRenewal(state)
                    return .none
                }
                return askForRun(&state)
            case let .leaseExpired(serial):
                // The reducer already dropped the expired lease; a newer one stays.
                guard state.lease.map({ $0.serial == serial }) ?? true else { return .none }
                state.lease = nil
                return askForRun(&state)
            case let .runRetryDue(generation):
                guard generation == state.refresh.runRetryGeneration, state.refresh.isRetryScheduled else { return .none }
                state.refresh.isRetryScheduled = false
                guard needsRenewal(state), state.refresh.inFlight == nil else { return .none }
                return requestRefresh(&state)
            case let .stageEnded(generation):
                guard generation == state.runGeneration else { return .none }
                state.run?.isStageOver = true
                return askForRun(&state)
            case .event, .statusRead, .refreshAnswered, .refreshFailed, .refreshTimedOut, .retryDue:
                return .none
        }
    }

    /// A lowered wrist hides the digits and stops renewing; raising it shows them again under a lease still alive and
    /// renews on its schedule, or asks once.
    func luminanceChanged(_ isReduced: Bool, _ state: inout State) -> Effect<Action> {
        let wasReduced = state.isLuminanceReduced
        state.isLuminanceReduced = isReduced
        if isReduced {
            state.refresh.isRenewalDue = false
            return .cancel(id: CancelID.renewal)
        }
        guard wasReduced, needsRenewal(state) else { return .none }
        // The renewal counts from the request in flight, or the one whose reply opened the lease. It names the newest
        // serial, which a later request whose reply asked nothing may have taken.
        let anchor = state.refresh.inFlight?.sentAt ?? state.lease?.sentAt
        let isStageOver = state.run?.isStageOver == true
        if let anchor, let elapsed = anchor.duration(toNowOf: clock), elapsed < Self.leaseRenewal,
           !isStageOver || state.refresh.inFlight != nil {
            let serial = state.refresh.lastSerial
            let remaining = Self.leaseRenewal - elapsed
            return .run { [clock] send in
                try await clock.sleep(for: remaining)
                await send(.internal(.renewalDue(serial: serial)))
            }
            .cancellable(id: CancelID.renewal, cancelInFlight: true)
        }
        if state.refresh.inFlight != nil {
            // Due already: the reply of the request in flight asks again at once.
            state.refresh.isRenewalDue = true
            return .none
        }
        return askForRun(&state)
    }
}
