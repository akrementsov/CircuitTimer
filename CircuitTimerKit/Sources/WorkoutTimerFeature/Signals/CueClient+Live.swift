import AVFAudio
import Foundation
import UIKit

extension CueClient {
    public static let liveValue: Self = {
        let engine = CueEngine()
        engine.queue.async { engine.observeSystem() }
        return Self(
            play: { try await play($0, engine: engine) },
            suspend: { owner, revision in await engine.perform { $0.suspend(owner: owner, through: revision) } },
            end: { owner in await engine.perform { $0.end(owner: owner) } }
        )
    }()

    private static func play(_ burst: CueBurst, engine: CueEngine) async throws -> CueResult {
        try Task.checkCancellation()
        guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else { return CueResult() }

        let voiceOver = await MainActor.run { UIAccessibility.isVoiceOverRunning }
        let text = burst.announcement?.text
        var voice: AVSpeechSynthesisVoice?
        var result = CueResult()
        if text != nil, !voiceOver {
            switch await engine.perform({ $0.voiceLookup() }) {
                case let .success(found): voice = found
                case let .failure(error): result.failures.insert(error)
            }
        }
        try Task.checkCancellation()
        var audioPermitted = false
        if burst.tone != nil || voice != nil {
            switch await engine.perform({ $0.start(owner: burst.owner, revision: burst.revision) }) {
                case .admitted: audioPermitted = true
                case .rejected: return CueResult()
                case .skipped: break
                case let .failed(error): result.failures.insert(error)
            }
        } else {
            // A missing voice must still stop speech left from an earlier stage.
            guard await engine.perform({ $0.preempt(owner: burst.owner, revision: burst.revision) }) else { return CueResult() }
        }
        if let text, voiceOver {
            let posted = await MainActor.run {
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return false }

                var attributed = AttributedString(text)
                attributed.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(attributed).post()
                return true
            }
            if posted { result.outputs.insert(.announcement) }
        }
        guard audioPermitted else { return result }
        try Task.checkCancellation()
        if let tone = burst.tone {
            let start = await engine.perform { $0.startTone(tone, owner: burst.owner, revision: burst.revision) }
            let completion = try await complete(start)
            switch completion {
                case .completed: result.outputs.insert(.tone)
                case .stopped: return result
                case let .failed(error): result.failures.insert(error)
            }
        }
        try Task.checkCancellation()
        if let text, let voice {
            let start = await engine.perform { $0.startSpeech(text, voice: voice, owner: burst.owner, revision: burst.revision) }
            let completion = try await complete(start)
            switch completion {
                case .completed: result.outputs.insert(.voice)
                case .stopped: return result
                case let .failed(error): result.failures.insert(error)
            }
        }
        return result
    }

    private enum Completion {
        case completed
        case stopped
        case failed(CueError)
    }

    private static func complete(_ start: CueEngine.OutputStart) async throws -> Completion {
        switch start {
            case .stopped: return .stopped
            case let .failed(error): return .failed(error)
            case let .playing(waiter):
                switch await waiter.wait() {
                    case .completed: return .completed
                    case .stopped: return .stopped
                    case .failed: return .failed(.playerFailed)
                    case .cancelled: throw CancellationError()
                }
        }
    }
}
