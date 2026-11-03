import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutDomain

/// One request at a time, asked only for a reason: the scene becoming active, the iPhone becoming reachable, a state
/// the order rules want confirmed, a shown run that needs its lease renewed, or a scheduled retry. A successful answer
/// schedules nothing for the list; new lists arrive as contexts and messages.
extension WatchRemoteFeature {
    struct RefreshRequest: Equatable, Sendable {
        let id: UUID
        let serial: Int
        /// When it was sent; a lease its reply opens counts from here.
        let sentAt: MonotonicInstant
    }

    static func retryDelay(afterFailures failures: Int) -> Duration {
        retryDelays[min(max(failures, 1), retryDelays.count) - 1]
    }

    func requestRefresh(_ state: inout State) -> Effect<Action> {
        guard state.refresh.inFlight == nil else {
            state.refresh.needsRefresh = true
            return .none
        }
        // The scene and the link come back with reasons of their own.
        guard state.isSceneActive, state.link?.canSend == true else { return .none }
        let requestID = uuid()
        state.refresh.lastSerial += 1
        let serial = state.refresh.lastSerial
        state.refresh.inFlight = RefreshRequest(id: requestID, serial: serial, sentAt: MonotonicInstant(now: clock))
        state.refresh.needsRefresh = false
        state.refresh.isRenewalDue = false
        // A retry scheduled before this request would only ask again after it.
        state.refresh.retryGeneration += 1
        state.refresh.runRetryGeneration += 1
        state.refresh.isRetryScheduled = false
        let request = WatchRequest.refresh(knownCatalogDigest: state.order.catalogDigest)
        return .merge(
            .cancel(id: CancelID.retry),
            .cancel(id: CancelID.runRetry),
            .run { [phoneCompanion] send in
                do {
                    let reply = try await phoneCompanion.send(requestID, request)
                    await send(.internal(.refreshAnswered(sentID: requestID, reply)))
                } catch is CancellationError {
                    return
                } catch let error as PhoneLinkError {
                    await send(.internal(.refreshFailed(sentID: requestID, error)))
                } catch {
                    Self.logger.error("A refresh failed outside the link: \(String(reflecting: error), privacy: .public)")
                    await send(.internal(.refreshFailed(sentID: requestID, .failed)))
                }
            }
            .cancellable(id: CancelID.refresh, cancelInFlight: true),
            .run { [clock] send in
                try await clock.sleep(for: Self.refreshTimeout)
                await send(.internal(.refreshTimedOut(sentID: requestID)))
            }
            .cancellable(id: CancelID.refreshTimeout, cancelInFlight: true),
            // A run's lease is renewed this long after the send, whatever the reply does meanwhile.
            .run { [clock] send in
                try await clock.sleep(for: Self.leaseRenewal)
                await send(.internal(.renewalDue(serial: serial)))
            }
            .cancellable(id: CancelID.renewal, cancelInFlight: true)
        )
    }

    /// Ends the request in flight if `sentID` is its ID; an action of an older request changes nothing.
    func finish(_ sentID: UUID, _ state: inout State) -> RefreshRequest? {
        guard let request = state.refresh.inFlight, request.id == sentID else { return nil }
        state.refresh.inFlight = nil
        return request
    }

    func refreshAnswered(sentID: UUID, _ envelope: WatchReplyEnvelope, _ state: inout State) -> Effect<Action> {
        guard let request = finish(sentID, &state) else { return .none }
        let ended = Effect<Action>.cancel(id: CancelID.refreshTimeout)
        let phoneState: PhoneState
        switch envelope.reply {
            case let .state(answered):
                phoneState = answered
            case .control, .start:
                // Only a bug answers a refresh with a command's reply; asking again would not fix it.
                Self.logger.error("The iPhone answered a refresh with a command's reply")
                state.problem = .incompatible(.phone)
                state.refresh.isRenewalDue = false
                return ended
            case nil:
                // The iPhone could not read the request.
                state.problem = .incompatible(Self.side(toUpdate: envelope.schemaVersion))
                state.refresh.isRenewalDue = false
                return ended
        }
        guard envelope.requestID == sentID else {
            // Only a bug answers with another request's ID; asking again would not fix it.
            Self.logger.error("The iPhone answered a request with another request's ID")
            state.problem = .incompatible(.phone)
            state.refresh.isRenewalDue = false
            return ended
        }
        state.refresh.hasAnswered = true
        state.problem = nil
        let shownBefore = state.run
        let outcome = state.order.receive(phoneState, from: .reply)
        // Decided before the run is applied: a reply that confirms nothing never counts as a reason of its own.
        let confirms = confirms(phoneState, of: request, isAccepted: outcome.change != nil, shownBefore: shownBefore, state)
        let applied = applyAccepted(outcome, phoneState, &state)
        let run: Effect<Action>
        if confirms, state.run != nil {
            state.refresh.failures = 0
            if state.commandNote?.note == .checking {
                // The confirmation shows what the iPhone did.
                state.commandNote = nil
            }
            let lease = openLease(from: request, &state)
            // New content whose stage already ended asks at once; the same content waits for the renewal, so clocks
            // that disagree by a little do not make a request per reply.
            let isNewStageOver = state.run?.isStageOver == true && shownBefore?.run != state.run?.run
            let renewal: Effect<Action> = state.refresh.isRenewalDue || isNewStageOver ? askForRun(&state) : .none
            state.refresh.isRenewalDue = false
            run = .merge(lease, renewal)
        } else if outcome.change == nil, phoneState.isRunLive, phoneState.processID == state.order.processID,
                  phoneState.run?.owner == state.run?.run.owner {
            // A live reply a newer message of the same process overtook: the iPhone answered; ask again at once for
            // the newer content rather than count it as a failure.
            state.refresh.isRenewalDue = false
            run = askForRun(&state)
        } else if needsRenewal(state) {
            state.refresh.isRenewalDue = false
            run = scheduleRunRetry(&state)
        } else {
            state.refresh.failures = 0
            state.refresh.isRenewalDue = false
            run = .none
        }
        // A request the run just sent was sent after this reply, so its own reply answers the list's reasons too.
        let list: Effect<Action> = if state.refresh.inFlight != nil {
            .none
        } else if outcome.asksAgain {
            requestRefresh(&state)
        } else {
            askAgainIfNeeded(&state)
        }
        return .merge(ended, applied, run, list)
    }

    /// A reply confirms the run when the run's own timer answered within the lease of its request, and the state was
    /// accepted, or it is the same process's reply about exactly the content shown under a live state, overtaken by a
    /// newer message.
    private func confirms(
        _ phoneState: PhoneState,
        of request: RefreshRequest,
        isAccepted: Bool,
        shownBefore: ShownRun?,
        _ state: State
    ) -> Bool {
        guard phoneState.isRunLive, let run = phoneState.run,
              let elapsed = request.sentAt.duration(toNowOf: clock), elapsed < Self.confirmationLease else { return false }
        if isAccepted { return true }
        return phoneState.processID == state.order.processID && shownBefore?.run == run && shownBefore?.isLive == true
    }

    func refreshFailed(sentID: UUID, _ error: PhoneLinkError, _ state: inout State) -> Effect<Action> {
        guard finish(sentID, &state) != nil else { return .none }
        let ended = Effect<Action>.merge(.cancel(id: CancelID.refreshTimeout), dropRunRenewal(&state))
        // An end no retry can fix keeps `needsRefresh`: the reason waits for the next request a status, the scene or a
        // state starts, instead of asking again into the same failure.
        switch error {
            case let .incompatible(peerSchemaVersion):
                state.problem = .incompatible(Self.side(toUpdate: peerSchemaVersion))
                return ended
            case .companionMissing:
                state.problem = .companionMissing
                return ended
            case .inactive:
                // Activation brings the session back and reports it.
                state.problem = .unreachable
                return ended
            case .unreachable:
                state.problem = .unreachable
                return .merge(ended, scheduleRetry(&state))
            case .timedOut, .payloadTooLarge, .failed:
                state.problem = .failed
                return .merge(ended, scheduleRetry(&state))
        }
    }

    /// A failed request drops the run's pending renewal: the retry asks for the run too, after its delay.
    func dropRunRenewal(_ state: inout State) -> Effect<Action> {
        state.refresh.isRenewalDue = false
        return .cancel(id: CancelID.renewal)
    }

    func scheduleRetry(_ state: inout State) -> Effect<Action> {
        if state.refresh.needsRefresh {
            return requestRefresh(&state)
        }
        guard state.isSceneActive else { return .none }
        state.refresh.failures += 1
        state.refresh.retryGeneration += 1
        state.refresh.isRetryScheduled = true
        let generation = state.refresh.retryGeneration
        let delay = Self.retryDelay(afterFailures: state.refresh.failures)
        return .run { [clock] send in
            try await clock.sleep(for: delay)
            await send(.internal(.retryDue(generation)))
        }
        .cancellable(id: CancelID.retry, cancelInFlight: true)
    }

    private func askAgainIfNeeded(_ state: inout State) -> Effect<Action> {
        state.refresh.needsRefresh ? requestRefresh(&state) : .none
    }
}
