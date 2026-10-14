import AVFAudio

/// Native players stay on the engine queue; this boundary also permits testing preparation without audio hardware.
protocol CuePlayer: AnyObject {
    var delegate: (any AVAudioPlayerDelegate)? { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: CuePlayer {}
