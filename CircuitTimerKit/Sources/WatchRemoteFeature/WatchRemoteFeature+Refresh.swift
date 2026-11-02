import ComposableArchitecture
import Foundation
import WatchLink

/// One request at a time, asked only for a reason: the scene becoming active, the iPhone becoming reachable, a state
/// the order rules want confirmed, or a scheduled retry. A successful answer schedules nothing; new lists arrive as
/// contexts and messages.
extension WatchRemoteFeature {
    func requestRefresh(_ state: inout State) -> Effect<Action> {
        guard state.refresh.inFlight == nil else {
            state.refresh.needsRefresh = true
            return .none
        }
        // The scene and the link come back with reasons of their own.
        guard state.isSceneActive, state.link?.canSend == true else { return .none }
        let requestID = uuid()
        state.refresh.inFlight = requestID
        state.refresh.needsRefresh = false
        // A retry scheduled before this request would only ask again after it.
        state.refresh.retryGeneration += 1
        let request = WatchRequest.refresh(knownCatalogDigest: state.order.catalogDigest)
        return .merge(
            .cancel(id: CancelID.retry),
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
            .cancellable(id: CancelID.refreshTimeout, cancelInFlight: true)
        )
    }

    /// Ends the request in flight if `sentID` is its ID; an action of an older request changes nothing.
    func finish(_ sentID: UUID, _ state: inout State) -> Bool {
        guard state.refresh.inFlight == sentID else { return false }
        state.refresh.inFlight = nil
        return true
    }

    func refreshAnswered(sentID: UUID, _ envelope: WatchReplyEnvelope, _ state: inout State) -> Effect<Action> {
        guard finish(sentID, &state) else { return .none }
        let ended = Effect<Action>.cancel(id: CancelID.refreshTimeout)
        guard case let .state(phoneState) = envelope.reply else {
            // The iPhone could not read the request.
            state.problem = .incompatible(Self.side(toUpdate: envelope.schemaVersion))
            return ended
        }
        guard envelope.requestID == sentID else {
            // Only a bug answers with another request's ID; asking again would not fix it.
            Self.logger.error("The iPhone answered a request with another request's ID")
            state.problem = .incompatible(.phone)
            return ended
        }
        state.refresh.failures = 0
        state.refresh.hasAnswered = true
        state.problem = nil
        let received = receive(phoneState, from: .reply, &state)
        return .merge(ended, received, askAgainIfNeeded(&state))
    }

    func refreshFailed(sentID: UUID, _ error: PhoneLinkError, _ state: inout State) -> Effect<Action> {
        guard finish(sentID, &state) else { return .none }
        let ended = Effect<Action>.cancel(id: CancelID.refreshTimeout)
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

    func scheduleRetry(_ state: inout State) -> Effect<Action> {
        if state.refresh.needsRefresh {
            return requestRefresh(&state)
        }
        guard state.isSceneActive else { return .none }
        state.refresh.failures += 1
        state.refresh.retryGeneration += 1
        let generation = state.refresh.retryGeneration
        let delay = Self.retryDelays[min(state.refresh.failures, Self.retryDelays.count) - 1]
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
