import ComposableArchitecture
import Foundation
import WatchLink
import WorkoutActivity

/// Pause and Resume from the watch. A command is a request of its own beside the refresh loop; the iPhone's timer
/// applies it by the Live Activity card's rules. Its reply comes in as a reply: it carries a live lease on to the new
/// content of the same timer or revokes it, but never opens one, and only a refresh's reply switches the iPhone
/// process the watch follows.
extension WatchRemoteFeature {
    static let commandTimeout: Duration = .seconds(10)

    /// The command waiting for its reply.
    struct CommandRequest: Equatable, Sendable {
        let id: UUID
        /// The timer it was sent to; a reply about another timer shows no outcome.
        let owner: UUID
        let command: LiveActivityCommand
    }

    enum CommandNote: Equatable, Sendable {
        /// The command may have applied; the next confirmation shows what the iPhone did.
        case checking
        /// The workout changed on the iPhone before the command reached it.
        case changed
        /// The iPhone did not apply the command.
        case failed
    }

    /// An outcome, shown only while the watch shows the run it is about.
    struct ShownCommandNote: Equatable, Sendable {
        let note: CommandNote
        let run: WatchRun
    }

    func controlButtonTapped(_ state: inout State) -> Effect<Action> {
        // A tap after the stage's end, before its `stageEnded` arrives, would pause a stage the watch does not show.
        guard case let .run(screen) = state.screen, case let .button(control) = screen.controlSlot, control.isEnabled,
              date() < control.until, let shown = state.run else { return .none }
        let id = uuid()
        state.command = CommandRequest(id: id, owner: shown.run.owner, command: control.command)
        state.commandNote = nil
        let request = WatchRequest.control(
            owner: shown.run.owner,
            command: control.command,
            generation: shown.run.content.controlGeneration,
            knownCatalogDigest: state.order.catalogDigest
        )
        return .merge(
            .run { [phoneCompanion] send in
                do {
                    let reply = try await phoneCompanion.send(id, request)
                    await send(.internal(.commandAnswered(sentID: id, reply)))
                } catch is CancellationError {
                    return
                } catch let error as PhoneLinkError {
                    await send(.internal(.commandFailed(sentID: id, error)))
                } catch {
                    Self.logger.error("A command failed outside the link: \(String(reflecting: error), privacy: .public)")
                    await send(.internal(.commandFailed(sentID: id, .failed)))
                }
            }
            .cancellable(id: CancelID.command, cancelInFlight: true),
            .run { [clock] send in
                try await clock.sleep(for: Self.commandTimeout)
                await send(.internal(.commandTimedOut(sentID: id)))
            }
            .cancellable(id: CancelID.commandTimeout, cancelInFlight: true)
        )
    }

    /// Ends the command waiting if `sentID` is its ID; an action of an older command changes nothing, its reply
    /// included: its state comes again as a message or in a refresh's reply.
    func finishCommand(_ sentID: UUID, _ state: inout State) -> CommandRequest? {
        guard let command = state.command, command.id == sentID else { return nil }
        state.command = nil
        return command
    }

    func commandAnswered(sentID: UUID, _ envelope: WatchReplyEnvelope, _ state: inout State) -> Effect<Action> {
        guard let command = finishCommand(sentID, &state) else { return .none }
        let ended = Effect<Action>.cancel(id: CancelID.commandTimeout)
        let result: WatchControlResult
        let phoneState: PhoneState
        switch envelope.reply {
            case let .control(answered, answeredState) where envelope.requestID == sentID:
                result = answered
                phoneState = answeredState
            case nil:
                // The iPhone could not read the command.
                state.problem = .incompatible(Self.side(toUpdate: envelope.schemaVersion))
                return ended
            case .control, .state:
                // Only a bug answers a command with another request's ID or a refresh's reply.
                Self.logger.error("The iPhone answered a command with another request's reply")
                state.problem = .incompatible(.phone)
                return ended
        }
        let received: Effect<Action>
        if phoneState.processID != state.order.processID {
            // Another iPhone process: an unsolicited state, which only a refresh's reply may make the one followed.
            received = receive(phoneState, from: .message, &state)
        } else {
            state.refresh.hasAnswered = true
            received = receive(phoneState, from: .reply, &state)
            let note: CommandNote? = switch result {
                case .applied:
                    nil
                case .stale:
                    .changed
                case .busy, .unavailable:
                    .failed
                case .timedOut:
                    .checking
            }
            showOutcome(note, of: command, &state)
        }
        return .merge(ended, received, askAfterCommand(&state))
    }

    func commandFailed(sentID: UUID, _ error: PhoneLinkError, _ state: inout State) -> Effect<Action> {
        guard let command = finishCommand(sentID, &state) else { return .none }
        let ended = Effect<Action>.cancel(id: CancelID.commandTimeout)
        switch error {
            case let .incompatible(peerSchemaVersion):
                state.problem = .incompatible(Self.side(toUpdate: peerSchemaVersion))
                return ended
            case .companionMissing, .payloadTooLarge:
                // WatchConnectivity refused the command before sending it.
                showOutcome(.failed, of: command, &state)
            case .inactive, .unreachable, .timedOut, .failed:
                // The command may have left before the link failed.
                showOutcome(.checking, of: command, &state)
        }
        return .merge(ended, askAfterCommand(&state))
    }

    func commandTimedOut(sentID: UUID, _ state: inout State) -> Effect<Action> {
        guard let command = finishCommand(sentID, &state) else { return .none }
        showOutcome(.checking, of: command, &state)
        return .merge(.cancel(id: CancelID.command), askAfterCommand(&state))
    }

    /// The outcome shows on the run the command was about; a reply about another timer shows none.
    private func showOutcome(_ note: CommandNote?, of command: CommandRequest, _ state: inout State) {
        guard let note, let run = state.run?.run, run.owner == command.owner else { return }
        state.commandNote = ShownCommandNote(note: note, run: run)
    }

    /// One request after a command left the run without a confirmation; a scheduled retry does not hold it back.
    /// With the wrist lowered nothing is asked, as for the run's renewal.
    private func askAfterCommand(_ state: inout State) -> Effect<Action> {
        guard needsRenewal(state), state.refresh.inFlight == nil, state.lease == nil else { return .none }
        return requestRefresh(&state)
    }
}
