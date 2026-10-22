import Sharing

// The key string is stored in the user's defaults: renaming it silently resets the choice.
// It contains no dots, because `UserDefaults` cannot observe a dotted key path.
extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
    /// Whether workouts sync through iCloud. A change takes effect at the next launch, which opens the store again.
    public static var iCloudSync: Self {
        Self[.appStorage("iCloudSync"), default: true]
    }
}
