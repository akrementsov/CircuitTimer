import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutDomain

extension WatchRemoteFeature {
    static let startSendTimeout: Duration = .seconds(10)
    /// The iPhone's thirty seconds, counted conservatively from the reply, plus five seconds for publication.
    static let startRunTimeout: Duration = .seconds(35)

    struct StartRequest: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case sending
            case waiting(asksOnPhone: Bool)
        }

        let id: UUID
        var beganAt: MonotonicInstant
        var stage = Stage.sending
        var timeoutGeneration = 0

        var timeout: Duration { stage == .sending ? WatchRemoteFeature.startSendTimeout : WatchRemoteFeature.startRunTimeout }
    }

    enum StartNote: Equatable, Sendable {
        case sending
        case starting
        case asksOnPhone
        case openPhoneApp
        case busy
        case listUnavailable
        case changed
        case gone
        case notPlayable
        /// A lost reply or missing publication never proves the workout did not start.
        case checkPhone
    }

    func workoutTapped(_ id: UUID, _ state: inout State) -> Effect<Action> {
        guard state.start == nil, case .list = state.screen,
              let entry = state.catalog?.lastLoaded?.entries.first(where: { $0.id == id }) else {
            return .none
        }
        state.startNote = nil
        state.path.removeAll()
        state.path.append(.selected(id: id, fingerprint: entry.scheduleFingerprint))
        return .none
    }

    func startButtonTapped(_ state: inout State) -> Effect<Action> {
        guard state.canStartSelected, case let .ready(entry) = state.selection else { return .none }
        let id = uuid()
        let pending = StartRequest(id: id, beganAt: MonotonicInstant(now: clock))
        state.start = pending
        state.startNote = nil
        let request = WatchRequest.start(
            workoutID: entry.id, scheduleFingerprint: entry.scheduleFingerprint, knownCatalogDigest: state.order.catalogDigest
        )
        return .merge(
            .run { [phoneCompanion] send in
                do {
                    let reply = try await phoneCompanion.send(id, request)
                    await send(.internal(.startAnswered(sentID: id, reply)))
                } catch is CancellationError {
                    return
                } catch let error as PhoneLinkError {
                    await send(.internal(.startFailed(sentID: id, error)))
                } catch {
                    Self.logger.error("A Start failed outside the link: \(String(reflecting: error), privacy: .public)")
                    await send(.internal(.startFailed(sentID: id, .failed)))
                }
            }
            .cancellable(id: CancelID.start, cancelInFlight: true),
            startTimeout(pending)
        )
    }

    private func startTimeout(_ request: StartRequest) -> Effect<Action> {
        .run { [clock] send in
            do {
                try await clock.sleep(for: request.timeout)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("A watch Start wait failed: \(String(reflecting: error), privacy: .public)")
            }
            await send(.internal(.startTimedOut(sentID: request.id, generation: request.timeoutGeneration)))
        }
        .cancellable(id: CancelID.startTimeout, cancelInFlight: true)
    }

    func startAnswered(sentID: UUID, _ envelope: WatchReplyEnvelope, _ state: inout State) -> Effect<Action> {
        guard let pending = state.start, pending.id == sentID, pending.stage == .sending else {
            Self.logger.notice("Ignored a late Start reply")
            return .none
        }
        guard envelope.requestID == sentID, case let .start(result, phoneState) = envelope.reply else {
            Self.logger.error("The iPhone answered Start with an incompatible reply")
            state.problem = .incompatible(Self.side(toUpdate: envelope.schemaVersion))
            return stopStart(note: nil, &state)
        }
        // A direct result belongs to this UUID even if a newer state overtook its PhoneState. Only refresh may
        // switch processes. Taking this state as a message preserves that rule and never opens a lease.
        let source: StateSource = phoneState.processID == state.order.processID ? .reply : .message
        let received = receive(phoneState, from: source, &state)
        guard state.run == nil, !state.isRunTooLarge else { return .merge(received, stopStart(note: nil, &state)) }
        switch result {
            case let .accepted(asksOnPhone):
                let waiting = StartRequest(
                    id: sentID,
                    beganAt: MonotonicInstant(now: clock),
                    stage: .waiting(asksOnPhone: asksOnPhone),
                    timeoutGeneration: pending.timeoutGeneration + 1
                )
                state.start = waiting
                return .merge(received, .cancel(id: CancelID.startTimeout), startTimeout(waiting))
            case .openPhoneApp:
                return .merge(received, stopStart(note: .openPhoneApp, &state))
            case .busy:
                return .merge(received, stopStart(note: .busy, &state))
            case .listUnavailable:
                state.path.removeAll()
                return .merge(received, stopStart(note: .listUnavailable, &state))
            case .changed:
                state.path.removeAll()
                return .merge(received, stopStart(note: .changed, &state))
            case .gone:
                state.path.removeAll()
                return .merge(received, stopStart(note: .gone, &state))
            case .notPlayable:
                state.path.removeAll()
                return .merge(received, stopStart(note: .notPlayable, &state))
        }
    }

    func startFailed(sentID: UUID, _ error: PhoneLinkError, _ state: inout State) -> Effect<Action> {
        guard state.start?.id == sentID, state.start?.stage == .sending else { return .none }
        if case let .incompatible(version) = error {
            state.problem = .incompatible(Self.side(toUpdate: version))
            return stopStart(note: nil, &state)
        }
        return stopStart(note: .checkPhone, &state)
    }

    /// Ends only the local wait: the iPhone may already have accepted and executed the request.
    func stopStart(note: StartNote?, _ state: inout State) -> Effect<Action> {
        state.start = nil
        state.startNote = note
        return .merge(.cancel(id: CancelID.start), .cancel(id: CancelID.startTimeout))
    }

    func dropExpiredStart(_ state: inout State) -> Effect<Action> {
        guard let pending = state.start else { return .none }
        guard let elapsed = pending.beganAt.duration(toNowOf: clock), elapsed < pending.timeout else {
            return stopStart(note: .checkPhone, &state)
        }
        return .none
    }

    /// Selection is a reference into the current catalog, never a copied workout. Back affects only the path.
    func reconcileSelectionAndStart(_ state: inout State) -> Effect<Action> {
        if case .incompatible = state.problem {
            state.path.removeAll()
            return stopStart(note: nil, &state)
        }
        if state.run != nil || state.isRunTooLarge {
            state.path.removeAll()
            if state.start != nil || state.startNote != nil { return stopStart(note: nil, &state) }
            return .none
        }
        let note: StartNote
        switch state.selection {
            case .ready, .unconfirmed, nil:
                return .none
            case .unavailable:
                note = .listUnavailable
            case .gone:
                note = .gone
            case .changed:
                note = .changed
            case .notPlayable:
                note = .notPlayable
        }
        state.path.removeAll()
        if state.start == nil { state.startNote = note }
        return .none
    }
}

extension WatchRemoteFeature.State {
    enum Selection: Equatable {
        case ready(WatchCatalog.Entry)
        case unconfirmed(WatchCatalog.Entry)
        case unavailable
        case gone
        case changed
        case notPlayable
    }

    func selection(id: UUID, fingerprint: String) -> Selection {
        guard let catalog, catalog.unavailable == nil, let loaded = catalog.lastLoaded else { return .unavailable }
        guard let entry = loaded.entries.first(where: { $0.id == id }) else { return .gone }
        guard entry.scheduleFingerprint == fingerprint else { return .changed }
        guard entry.isPlayable else { return .notPlayable }
        return order.vouchesForCatalog ? .ready(entry) : .unconfirmed(entry)
    }

    var selection: Selection? {
        guard case let .selected(id, fingerprint) = path.last else { return nil }
        return selection(id: id, fingerprint: fingerprint)
    }

    var canStartSelected: Bool {
        if case .incompatible = problem { return false }
        guard isSceneActive, link?.canSend == true,
              start == nil, run == nil, !isRunTooLarge, case .ready = selection else { return false }
        return true
    }

    var startStatus: WatchRemoteFeature.StartNote? {
        if let start {
            switch start.stage {
                case .sending: return .sending
                case .waiting(asksOnPhone: true): return .asksOnPhone
                case .waiting(asksOnPhone: false): return .starting
            }
        }
        return startNote
    }
}
