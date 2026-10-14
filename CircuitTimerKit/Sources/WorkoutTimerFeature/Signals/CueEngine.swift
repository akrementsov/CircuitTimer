import AVFAudio
import ComposableArchitecture
import Foundation
import os

/// All mutable state belongs to `queue`; state methods check confinement even on iOS 17.
/// While active without an output, one valid idle deadline exists. Only a started output invalidates it.
/// Cancellation ends the task's wait, while a newer cue, suspend, close or idle deadline owns teardown.
final class CueEngine: @unchecked Sendable {
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
        var player: AVAudioPlayer?
        var synthesizer: AVSpeechSynthesizer?
        let delegate: AnyObject
        let waiter: OutputWaiter
    }

    let queue = DispatchQueue(label: "CircuitTimer.Cues", qos: .userInitiated)
    private let session: CueAudioSession
    private let idleScheduler: AnySchedulerOf<DispatchQueue>
    var observerTokens: [NSObjectProtocol] = []
    private var owner: UUID?
    private var latest = 0
    private var limit = 0
    private var suspendedThrough: [UUID: Int] = [:]
    private var tombstones: Set<UUID> = []
    private var sceneActive = true
    private var sessionActive = false
    private var idleToken = 0
    private var output: Output?
    private var nextOutputID = 0
    private var toneData: [CueTone: Data] = [:]
    private var loggedMissingTones: Set<CueTone> = []
    private var cachedVoice: Result<AVSpeechSynthesisVoice, CueError>?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "Cues")

    init(session: CueAudioSession = .live, idleScheduler: AnySchedulerOf<DispatchQueue>? = nil) {
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
            self.owner = owner
            latest = 0
            limit = suspendedThrough[owner] ?? 0
        }
        latest = revision
        stopOutput()
        idleToken += 1
        return true
    }

    func start(owner: UUID, revision: Int) -> StartResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard admit(owner: owner, revision: revision) else { return .rejected }
        defer { if sessionActive { scheduleIdle() } }
        guard !sessionActive else { return .admitted }

        do {
            try session.activate()
            sessionActive = true
            return .admitted
        } catch {
            let code = (error as NSError).code
            if [560_557_684, 561_017_449, 1_936_290_409, 561_015_905].contains(code) {
                Self.logger.info("Cue audio session was skipped: \(code)")
                return .skipped
            }
            Self.logger.error("Activating cue audio failed: \(String(reflecting: error), privacy: .public)")
            return .failed(.sessionFailed(code: code))
        }
    }

    func preempt(owner: UUID, revision: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard admit(owner: owner, revision: revision) else { return false }
        if sessionActive { scheduleIdle() }
        return true
    }

    private func canOutput(owner: UUID, revision: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return self.owner == owner && latest == revision && revision > limit && sessionActive && sceneActive
    }

    func startTone(_ tone: CueTone, owner: UUID, revision: Int) -> OutputStart {
        dispatchPrecondition(condition: .onQueue(queue))
        guard canOutput(owner: owner, revision: revision) else { return .stopped }
        guard let data = data(for: tone) else { return .failed(.toneMissing) }

        do {
            let player = try AVAudioPlayer(data: data)
            let waiter = OutputWaiter()
            nextOutputID += 1
            let delegate = ToneDelegate(waiter: waiter, outputID: nextOutputID, engine: self)
            player.delegate = delegate
            player.prepareToPlay()
            guard player.play() else {
                Self.logger.error("Cue player did not start")
                return .failed(.playerFailed)
            }
            output = Output(id: nextOutputID, player: player, delegate: delegate, waiter: waiter)
            idleToken += 1
            return .playing(waiter)
        } catch {
            Self.logger.error("Creating cue player failed: \(String(reflecting: error), privacy: .public)")
            return .failed(.playerFailed)
        }
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
                sessionActive = false
                idleToken += 1
                Self.logger.info("Cue audio was interrupted")
            case .interruptionEnded:
                Self.logger.info("Cue audio interruption ended")
            case let .routeChanged(reason):
                Self.logger.info("Cue audio route changed: \(reason)")
            case .mediaServicesReset:
                output?.waiter.finish(.stopped)
                output = nil
                sessionActive = false
                idleToken += 1
                toneData.removeAll()
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

    private func deactivate() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleToken += 1
        do {
            try session.deactivate()
        } catch {
            Self.logger.info("Deactivating cue audio failed: \(String(reflecting: error), privacy: .public)")
        }
        sessionActive = false
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
        guard token == idleToken, output == nil, sessionActive else { return }

        deactivate()
    }
}
