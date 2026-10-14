import AVFAudio
import ComposableArchitecture
import Foundation
import os

/// All mutable state belongs to `queue`; state methods check confinement even on iOS 17.
/// While active or awaiting a deactivation retry without output, one valid idle deadline exists.
/// Cancellation ends the task's wait, while a newer cue, suspend, close or idle deadline owns teardown.
final class CueEngine: @unchecked Sendable {
    private enum DeactivationState {
        case settled
        case retryPending
        case retryExhausted
    }

    enum StartResult: Equatable, Sendable {
        case admitted
        case rejected
        case skipped
        case failed(CueError)
    }

    enum OutputStart: Sendable {
        case playing(OutputWaiter)
        case stopped
        case failed(CueError)
    }

    struct Output {
        let id: Int
        var player: (any CuePlayer)?
        var synthesizer: AVSpeechSynthesizer?
        let delegate: AnyObject
        let waiter: OutputWaiter
    }

    let queue = DispatchQueue(label: "CircuitTimer.Cues", qos: .userInitiated)
    private let session: CueAudioSession
    private let makePlayer: @Sendable (Data) throws -> any CuePlayer
    private let idleScheduler: AnySchedulerOf<DispatchQueue>
    var observerTokens: [NSObjectProtocol] = []
    private var owner: UUID?
    private var latest = 0
    private var limit = 0
    private var suspendedThrough: [UUID: Int] = [:]
    private var tombstones: Set<UUID> = []
    private var sceneActive = true
    private var sessionActive = false
    private var deactivationState = DeactivationState.settled
    private var idleToken = 0
    private var output: Output?
    private var nextOutputID = 0
    private var toneData: [CueTone: Data] = [:]
    private var preparedPlayers: [CueTone: any CuePlayer] = [:]
    private var loggedMissingTones: Set<CueTone> = []
    private var cachedVoice: Result<AVSpeechSynthesisVoice, CueError>?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "Cues")

    init(
        session: CueAudioSession = .live,
        idleScheduler: AnySchedulerOf<DispatchQueue>? = nil,
        makePlayer: @escaping @Sendable (Data) throws -> any CuePlayer = { try AVAudioPlayer(data: $0) }
    ) {
        self.makePlayer = makePlayer
        self.session = session
        self.idleScheduler = idleScheduler ?? queue.eraseToAnyScheduler()
    }

    deinit {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
    }

    func perform<Value: Sendable>(_ work: @escaping @Sendable (CueEngine) -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }

    func post(_ event: CueEvent) {
        queue.async { self.handle(event) }
    }

    func outputDidEnd(_ id: Int) {
        queue.async { self.outputEnded(id) }
    }

    private func admit(owner: UUID, revision: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard sceneActive, !tombstones.contains(owner), revision > (suspendedThrough[owner] ?? 0) else { return false }
        if self.owner == owner {
            guard revision > max(latest, limit) else { return false }
        } else {
            clearPreparedPlayers()
            self.owner = owner
            latest = 0
            limit = suspendedThrough[owner] ?? 0
        }
        latest = revision
        stopOutput()
        idleToken += 1
        return true
    }

    func prepare(owner: UUID, revision: Int) -> CueResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard sceneActive, !tombstones.contains(owner), revision > (suspendedThrough[owner] ?? 0) else { return CueResult() }
        if self.owner != owner {
            stopOutput()
            clearPreparedPlayers()
            self.owner = owner
            latest = 0
            limit = suspendedThrough[owner] ?? 0
        }
        guard revision > max(latest, limit) else { return CueResult() }
        latest = revision
        stopOutput()
        idleToken += 1
        switch activate() {
            case .admitted:
                switch preparedPlayer(for: .countdown) {
                    case let .success(player):
                        preparedPlayers[.countdown] = player
                        scheduleIdle()
                        return CueResult()
                    case let .failure(error):
                        deactivate()
                        return CueResult(failures: [error])
                }
            case let .failed(error):
                if deactivationState == .retryPending { scheduleIdle() }
                return CueResult(failures: [error])
            case .rejected, .skipped:
                if deactivationState == .retryPending { scheduleIdle() }
                return CueResult()
        }
    }

    func start(owner: UUID, revision: Int) -> StartResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard admit(owner: owner, revision: revision) else { return .rejected }
        defer { if sessionActive || deactivationState == .retryPending { scheduleIdle() } }
        return activate()
    }

    private func activate() -> StartResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !sessionActive else { return .admitted }

        do {
            try session.activate()
            sessionActive = true
            deactivationState = .settled
            return .admitted
        } catch {
            let code = (error as NSError).code
            switch AVAudioSession.ErrorCode(rawValue: code) {
                // System-owned audio or a background transition skips this cue without a persistent failure notice.
                case .cannotInterruptOthers, .insufficientPriority, .siriIsRecording, .cannotStartPlaying:
                    Self.logger.info("Cue audio session was skipped: \(code)")
                    return .skipped
                default:
                    Self.logger.error("Activating cue audio failed: \(String(reflecting: error), privacy: .public)")
                    return .failed(.sessionFailed(code: code))
            }
        }
    }

    func preempt(owner: UUID, revision: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard admit(owner: owner, revision: revision) else { return false }
        if sessionActive || deactivationState == .retryPending { scheduleIdle() }
        return true
    }

    private func canOutput(owner: UUID, revision: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return self.owner == owner && latest == revision && revision > limit && sessionActive && sceneActive
    }

    func startTone(_ tone: CueTone, owner: UUID, revision: Int) -> OutputStart {
        dispatchPrecondition(condition: .onQueue(queue))
        guard canOutput(owner: owner, revision: revision) else { return .stopped }
        let player: any CuePlayer
        switch preparedPlayer(for: tone) {
            case let .success(prepared): player = prepared
            case let .failure(error): return .failed(error)
        }
        let waiter = OutputWaiter()
        nextOutputID += 1
        let delegate = ToneDelegate(waiter: waiter, outputID: nextOutputID, engine: self)
        player.delegate = delegate
        guard player.play() else {
            player.stop()
            Self.logger.error("Cue player did not start")
            return .failed(.playerFailed)
        }
        output = Output(id: nextOutputID, player: player, delegate: delegate, waiter: waiter)
        idleToken += 1
        return .playing(waiter)
    }

    private func preparedPlayer(for tone: CueTone) -> Result<any CuePlayer, CueError> {
        dispatchPrecondition(condition: .onQueue(queue))
        // A prepared player is consumed once; a delayed callback can never target a later playback of that player.
        if let player = preparedPlayers.removeValue(forKey: tone) { return .success(player) }
        guard let data = data(for: tone) else { return .failure(.toneMissing) }

        do {
            let player = try makePlayer(data)
            guard player.prepareToPlay() else {
                player.stop()
                Self.logger.error("Cue player preparation failed")
                return .failure(.playerFailed)
            }
            return .success(player)
        } catch {
            Self.logger.error("Creating cue player failed: \(String(reflecting: error), privacy: .public)")
            return .failure(.playerFailed)
        }
    }

    private func clearPreparedPlayers() {
        dispatchPrecondition(condition: .onQueue(queue))
        for player in preparedPlayers.values { player.stop() }
        preparedPlayers.removeAll()
    }

    private func data(for tone: CueTone) -> Data? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let data = toneData[tone] { return data }
        do {
            guard let url = tone.url else { throw CueError.toneMissing }
            let data = try Data(contentsOf: url)
            toneData[tone] = data
            return data
        } catch {
            if loggedMissingTones.insert(tone).inserted {
                Self.logger.error("Loading cue \(tone.rawValue, privacy: .public) failed: \(String(reflecting: error), privacy: .public)")
            }
            return nil
        }
    }

    func voiceLookup() -> Result<AVSpeechSynthesisVoice, CueError> {
        dispatchPrecondition(condition: .onQueue(queue))
        if let cachedVoice { return cachedVoice }
        let localization = Bundle.main.preferredLocalizations.first ?? "en"
        let language = voiceLanguage(forLocalization: localization)
        let result: Result<AVSpeechSynthesisVoice, CueError>
        if let voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: localization) {
            result = .success(voice)
        } else {
            Self.logger.error("No speech voice for app language \(language, privacy: .public)")
            result = .failure(.voiceUnavailable(language: language))
        }
        cachedVoice = result
        return result
    }

    func startSpeech(_ text: String, voice: AVSpeechSynthesisVoice, owner: UUID, revision: Int) -> OutputStart {
        dispatchPrecondition(condition: .onQueue(queue))
        guard canOutput(owner: owner, revision: revision) else { return .stopped }

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = true
        let waiter = OutputWaiter()
        nextOutputID += 1
        let delegate = SpeechDelegate(waiter: waiter, outputID: nextOutputID, engine: self)
        synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        output = Output(id: nextOutputID, synthesizer: synthesizer, delegate: delegate, waiter: waiter)
        idleToken += 1
        return .playing(waiter)
    }

    private func outputEnded(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard output?.id == id else { return }

        output = nil
        if sessionActive { scheduleIdle() }
    }

    func suspend(owner: UUID, through revision: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        suspendedThrough[owner] = max(suspendedThrough[owner] ?? 0, revision)
        guard self.owner == owner else { return }

        limit = max(limit, revision)
        if latest <= revision {
            stopOutput()
            deactivate()
        }
    }

    func end(owner: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        tombstones.insert(owner)
        suspendedThrough[owner] = nil
        guard self.owner == owner else { return }

        stopOutput()
        deactivate()
        self.owner = nil
    }

    func handle(_ event: CueEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
            case .resignedActive:
                sceneActive = false
                limit = latest
                stopOutput()
                deactivate()
            case .becameActive:
                sceneActive = true
                cachedVoice = nil
            case .interruptionBegan:
                stopOutput()
                clearPreparedPlayers()
                sessionActive = false
                deactivationState = .settled
                idleToken += 1
                Self.logger.info("Cue audio was interrupted")
            case .interruptionEnded:
                Self.logger.info("Cue audio interruption ended")
            case let .routeChanged(reason):
                // Our category notification may arrive after preparation without changing the output route.
                if reason != Int(AVAudioSession.RouteChangeReason.categoryChange.rawValue) { clearPreparedPlayers() }
                Self.logger.info("Cue audio route changed: \(reason)")
            case .mediaServicesReset:
                output?.waiter.finish(.stopped)
                output = nil
                sessionActive = false
                deactivationState = .settled
                idleToken += 1
                toneData.removeAll()
                preparedPlayers.removeAll()
                cachedVoice = nil
                Self.logger.error("Audio media services reset; cue caches were dropped")
            case .voicesChanged:
                cachedVoice = nil
        }
    }

    private func stopOutput() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let output else { return }

        self.output = nil
        output.player?.stop()
        output.synthesizer?.stopSpeaking(at: .immediate)
        output.waiter.finish(.stopped)
    }

    private func deactivate(retrying: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        clearPreparedPlayers()
        idleToken += 1
        sessionActive = false
        do {
            try session.deactivate()
            deactivationState = .settled
        } catch {
            Self.logger.error("Deactivating cue audio failed: \(String(reflecting: error), privacy: .public)")
            // isBusy already deactivates the session on iOS 17; rearming a deadline cannot replenish its retry budget.
            if (error as NSError).code == AVAudioSession.ErrorCode.isBusy.rawValue {
                deactivationState = .settled
            } else {
                deactivationState = retrying ? .retryExhausted : .retryPending
                if deactivationState == .retryPending { scheduleIdle() }
            }
        }
    }

    private func scheduleIdle() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleToken += 1
        let token = idleToken
        idleScheduler.schedule(after: idleScheduler.now.advanced(by: .milliseconds(1_500))) { [weak self] in
            guard let self else { return }
            queue.async { self.idleFired(token) }
        }
    }

    private func idleFired(_ token: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard token == idleToken, output == nil, sessionActive || deactivationState == .retryPending else { return }

        deactivate(retrying: deactivationState == .retryPending)
    }
}
