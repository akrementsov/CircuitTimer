import AVFAudio
import Foundation

final class ToneDelegate: NSObject, AVAudioPlayerDelegate, Sendable {
    let waiter: OutputWaiter
    let outputID: Int
    let engine: CueEngine

    init(waiter: OutputWaiter, outputID: Int, engine: CueEngine) {
        self.waiter = waiter
        self.outputID = outputID
        self.engine = engine
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        waiter.finish(flag ? .completed : .failed)
        engine.outputDidEnd(outputID)
        if !flag { CueEngine.logger.error("Cue player failed during playback") }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        waiter.finish(.failed)
        engine.outputDidEnd(outputID)
        CueEngine.logger.error("Cue decoding failed: \(String(reflecting: error), privacy: .public)")
    }
}
