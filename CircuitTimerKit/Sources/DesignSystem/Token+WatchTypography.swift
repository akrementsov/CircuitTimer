import SwiftUI

extension DesignSystem.Token {
    /// The watch app's text. Clocks use League Gothic at fixed sizes, as on the Live Activity, so the digits fill the
    /// small screen; text uses SF on Dynamic Type styles, because League Gothic has no Cyrillic.
    public enum WatchTypography: Sendable, CaseIterable {
        /// The running stage's clock.
        case stageClock
        /// The next stage's duration.
        case nextClock
        /// The running stage's name.
        case stageName
        /// The next stage's name.
        case nextName
        /// A screen's title and the workout's name.
        case title
        /// A workout in the list.
        case rowTitle
        /// The line under a workout in the list.
        case rowDetail
        /// Explanations and states.
        case footnote
        /// Start, Pause and Resume.
        case control
    }
}

extension Font {
    /// `.font(.token(.stageClock))`
    public static func token(_ style: DesignSystem.Token.WatchTypography) -> Font {
        switch style {
            case .stageClock:
                StageClockText.Face.current.font(size: 56)
            case .nextClock:
                StageClockText.Face.current.font(size: 22)
            case .stageName:
                .system(.headline, weight: .heavy)
            case .nextName:
                .system(.footnote, weight: .bold)
            case .title:
                .system(.headline, weight: .semibold)
            case .rowTitle:
                .system(.body, weight: .semibold)
            case .rowDetail, .footnote:
                .system(.footnote)
            case .control:
                .system(.body, weight: .semibold)
        }
    }
}
