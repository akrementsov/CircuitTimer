import AVFAudio
import Foundation

final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    let waiter: OutputWaiter
    let outputID: Int
    let engine: CueEngine

    init(waiter: OutputWaiter, outputID: Int, engine: CueEngine) {
        self.waiter = waiter
        self.outputID = outputID
        self.engine = engine
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        waiter.finish(.completed)
        engine.outputDidEnd(outputID)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        waiter.finish(.stopped)
        engine.outputDidEnd(outputID)
    }
}
