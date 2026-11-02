import SwiftUI

extension DesignSystem.Token {
    /// The watch app's text. Clocks use League Gothic at fixed sizes, as on the Live Activity, so the digits fill the
    /// small screen; text uses SF on Dynamic Type styles, because League Gothic has no Cyrillic. Case names differ
    /// from those of every other typography enum, so `.token(_:)` is never ambiguous and a case of another enum,
    /// written without its other arguments, never resolves to a watch font.
    public enum WatchTypography: Sendable {
        /// The running stage's clock.
        case runningStageClock
        /// The running stage's name.
        case runningStageName
        /// The next stage's name.
        case nextStageName
        /// A screen's title and the workout's name.
        case screenTitle
        /// A workout in the list.
        case rowTitle
        /// The line under a workout in the list.
        case rowDetail
        /// Explanations and states.
        case note
        /// Start, Pause and Resume.
        case control
    }
}

extension Font {
    /// `.font(.token(.runningStageClock))`
    public static func token(_ style: DesignSystem.Token.WatchTypography) -> Font {
        switch style {
            case .runningStageClock:
                StageClockText.Face.current.font(size: 56)
            case .runningStageName:
                .system(.headline, weight: .heavy)
            case .nextStageName:
                .system(.footnote, weight: .bold)
            case .screenTitle:
                .system(.headline, weight: .semibold)
            case .rowTitle:
                .system(.body, weight: .semibold)
            case .rowDetail, .note:
                .system(.footnote)
            case .control:
                .system(.body, weight: .semibold)
        }
    }
}
