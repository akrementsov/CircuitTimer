import SwiftUI

extension DesignSystem.Token {
    /// Text styles built on Dynamic Type so every size follows the user's accessibility setting.
    public enum Typography: Sendable, CaseIterable {
        case title
        case headline
        case body
        case caption
        /// The countdown on the timer screen: rounded, with fixed-width digits so it does not jitter.
        case timerLarge
    }
}

extension Font {
    /// `.font(.token(.headline))`
    public static func token(_ style: DesignSystem.Token.Typography) -> Font {
        switch style {
            case .title:
                .system(.title2, weight: .semibold)
            case .headline:
                .headline
            case .body:
                .body
            case .caption:
                .caption
            case .timerLarge:
                .system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
        }
    }
}
