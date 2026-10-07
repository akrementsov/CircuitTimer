import SwiftUI

extension DesignSystem.Token {
    /// Text styles built on Dynamic Type so every size follows the user's accessibility setting.
    public enum Typography: Sendable, CaseIterable {
        /// Legacy headline: 15 pt semibold on the subheadline style.
        case headline
        /// Legacy body: 15 pt on the subheadline style.
        case body
        /// Legacy footnote: 12 pt on the caption style.
        case footnote
        /// The countdown on the timer screen: rounded, with fixed-width digits so it does not jitter.
        case timerLarge
    }
}

extension Font {
    /// `.font(.token(.headline))`
    public static func token(_ style: DesignSystem.Token.Typography) -> Font {
        switch style {
            case .headline:
                .system(.subheadline, weight: .semibold)
            case .body:
                .subheadline
            case .footnote:
                .caption
            case .timerLarge:
                .system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
        }
    }
}
