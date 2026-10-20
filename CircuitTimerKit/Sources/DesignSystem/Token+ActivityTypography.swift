import SwiftUI

extension DesignSystem.Token {
    /// The Live Activity's text. Its sizes are fixed: iOS gives the Lock Screen and the Dynamic Island a fixed height,
    /// and the clock is their main content. Clocks use League Gothic; text uses SF, because League Gothic has no
    /// Cyrillic.
    public enum ActivityTypography: Sendable, CaseIterable {
        /// The stage clock on the Lock Screen card.
        case lockScreenClock
        /// The stage clock of the expanded Dynamic Island.
        case expandedClock
        /// The next stage's clock.
        case nextClock
        /// The clock of the compact Dynamic Island.
        case compactClock
        /// The clock of the minimal Dynamic Island.
        case minimalClock
        /// The current stage on the Lock Screen card.
        case lockScreenStageName
        /// The current stage in the expanded Dynamic Island.
        case expandedStageName
        /// The current stage in the compact Dynamic Island.
        case compactStageName
        /// The next stage.
        case nextName
        /// The workout's name.
        case title
        /// «Next», «Now».
        case label
        /// Pause/Resume inside the Live Activity's 44 pt target.
        case activityControl
    }
}

extension Font {
    /// `.font(.token(.lockScreenClock))`
    public static func token(_ style: DesignSystem.Token.ActivityTypography) -> Font {
        switch style {
            case .lockScreenClock:
                StageClockText.Face.current.font(size: 68)
            case .expandedClock:
                StageClockText.Face.current.font(size: 56)
            case .nextClock, .compactClock:
                StageClockText.Face.current.font(size: 22)
            case .minimalClock:
                StageClockText.Face.current.font(size: 17)
            case .lockScreenStageName:
                .system(size: 22, weight: .heavy)
            case .expandedStageName:
                .system(size: 20, weight: .heavy)
            case .compactStageName:
                .system(size: 12, weight: .heavy)
            case .nextName:
                .system(size: 14, weight: .bold)
            case .title:
                .system(size: 13, weight: .semibold)
            case .label:
                .system(size: 13)
            case .activityControl:
                .system(size: 22, weight: .semibold)
        }
    }
}
