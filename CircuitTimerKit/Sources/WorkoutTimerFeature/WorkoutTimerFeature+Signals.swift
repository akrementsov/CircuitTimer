import ComposableArchitecture
import Foundation

extension WorkoutTimerFeature {
    /// Called once after the action has settled the run. Off-screen moments are baselines, never a backlog.
    func signal(_ state: inout State) -> Effect<Action> {
        let enabled = state.isSoundOn || state.isVibrationOn || state.isSpeechOn
        guard enabled, state.isSceneActive, state.path.isEmpty, state.destination == nil else {
            guard state.signals.last != nil || state.isPreparingCountdown else { return .none }

            state.signals.last = nil
            state.haptic = nil
            let id = state.id
            let revision = state.signals.cueRevision
            return .merge(
                .cancel(id: CancelID.cues),
                .run { [cues] _ in await cues.suspend(id, revision) }
            )
        }
        guard !state.isPreparingCountdown else { return .none }
        if !state.isVibrationOn { state.haptic = nil }
        guard let event = state.signals.update(SignalMoment(state)) else { return .none }

        state.signals.cueRevision += 1
        let revision = state.signals.cueRevision
        if state.isVibrationOn {
            let kind: HapticCue.Kind = switch event.tone {
                case .countdown: .countdown
                case .stageStart: .stageStart
                case .finish: .finish
            }
            state.haptic = HapticCue(kind: kind, revision: revision)
        }
        let burst = CueBurst(
            owner: state.id,
            revision: revision,
            tone: state.isSoundOn ? event.tone : nil,
            announcement: state.isSpeechOn ? event.announcement : nil
        )
        let hadFailures = !state.cueFailures.isEmpty
        // Even a quiet event claims its revision, so turning off both audio outputs stops an older name.
        return .run { [cues] send in
            do {
                let result = try await cues.play(burst)
                if hadFailures || !result.failures.isEmpty {
                    await send(.internal(.cueFinished(revision: revision, result)))
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Cue client failed: \(String(reflecting: error), privacy: .public)")
                await send(.internal(.cueFinished(revision: revision, CueResult(failures: [.sessionFailed(code: 0)]))))
            }
        }
        .cancellable(id: CancelID.cues, cancelInFlight: true)
    }

    func cueFinished(revision: Int, result: CueResult, _ state: inout State) {
        guard revision == state.signals.cueRevision, state.isSceneActive else { return }
        if result.outputs.contains(.tone) { state.cueFailures.remove(.tone) }
        if !result.outputs.isDisjoint(with: [.tone, .voice]) { state.cueFailures.remove(.session) }
        if !result.outputs.isDisjoint(with: [.voice, .announcement]) { state.cueFailures.remove(.voice) }
        for error in result.failures {
            let failure: CueFailure = switch error {
                case .toneMissing, .playerFailed: .tone
                case .sessionFailed: .session
                case .voiceUnavailable: .voice
            }
            state.cueFailures.insert(failure)
        }
    }
}

extension WorkoutTimerFeature.State {
    var showsAudioFailure: Bool {
        (isSoundOn && cueFailures.contains(.tone))
            || ((isSoundOn || isSpeechOn) && cueFailures.contains(.session))
    }

    var showsVoiceFailure: Bool {
        isSpeechOn && cueFailures.contains(.voice)
    }
}
