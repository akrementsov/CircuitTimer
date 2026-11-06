/// Accessibility identifiers shared by the app and its UI tests, named `<screen>.<element>`. Elements the user
/// reads or types, like a workout's name, are found by their text instead; system elements by their own labels.
public enum AccessibilityID {
    public enum WorkoutList {
        public static let add = "workoutList.add"
        public static let empty = "workoutList.empty"
    }

    public enum Editor {
        public static let back = "editor.back"
        public static let name = "editor.name"
        public static let save = "editor.save"
        public static let start = "editor.start"

        /// A stage's name field by its section and place, independent of user data.
        public static func stageName(_ section: StageSection, _ index: Int) -> String {
            "editor.stageName.\(section.rawValue).\(index)"
        }

        /// A stage's duration field by its place on the screen, which stays put while the stage's name changes.
        public static func stageDuration(_ section: StageSection, _ index: Int) -> String {
            "editor.stageDuration.\(section.rawValue).\(index)"
        }
    }

    public enum Timer {
        public static let close = "timer.close"
        public static let currentStage = "timer.currentStage"
    }

    public enum Settings {
        public static let sound = "settings.sound"
        public static let vibration = "settings.vibration"
        public static let speech = "settings.speech"
        public static let backgroundNotifications = "settings.backgroundNotifications"
        public static let keepScreenOn = "settings.keepScreenOn"
        public static let iCloudSync = "settings.iCloudSync"
        public static let buyFullVersion = "settings.buyFullVersion"
        public static let restorePurchases = "settings.restorePurchases"
        public static let fullVersionPurchased = "settings.fullVersionPurchased"
        public static let about = "settings.about"
    }

    public enum Purchase {
        public static let close = "purchase.close"
        public static let buy = "purchase.buy"
        public static let restore = "purchase.restore"
        public static let retry = "purchase.retry"
        public static let done = "purchase.done"
        public static let reason = "purchase.reason"
        public static let pending = "purchase.pending"
        public static let purchased = "purchase.purchased"
    }

    public enum About {
        public static let version = "about.version"
        public static let privacyPolicy = "about.privacyPolicy"
        public static let termsOfUse = "about.termsOfUse"
    }
}

/// The editor's sections as the tests name them; the contract knows no workout model.
public enum StageSection: String, Sendable {
    case warmUp
    case training
    case coolDown
}
