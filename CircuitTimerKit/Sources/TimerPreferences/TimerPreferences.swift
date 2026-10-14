import Sharing

// The key strings are stored in the user's defaults: renaming one silently resets that choice.
// Keys contain no dots, because `UserDefaults` cannot observe a dotted key path.
extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
    /// Whether the timer plays its cue tones.
    public static var soundSignals: Self {
        Self[.appStorage("signalSound"), default: true]
    }

    /// Whether the timer vibrates at countdowns, stage starts and the finish.
    public static var vibrationSignals: Self {
        Self[.appStorage("signalVibration"), default: true]
    }

    /// Whether the timer speaks the name of each stage as it starts.
    public static var spokenStageNames: Self {
        Self[.appStorage("signalSpokenStageNames"), default: true]
    }

    /// Whether a running timer prevents automatic screen lock.
    public static var keepScreenOn: Self {
        Self[.appStorage("timerKeepScreenOn"), default: true]
    }
}
