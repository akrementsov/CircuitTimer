import AVFAudio

/// Keeps system audio calls replaceable when exercising the engine's teardown races.
struct CueAudioSession: Sendable {
    var activate: @Sendable () throws -> Void
    var deactivate: @Sendable () throws -> Void

    static let live = Self(
        activate: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .duckOthers)
            try session.setActive(true)
        },
        deactivate: {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    )
}
