import SwiftUI
import UIKit

extension DesignSystem.Token {
    /// Text styles built on Dynamic Type so every size follows the user's accessibility setting.
    public enum Typography: Sendable, CaseIterable {
        /// 15 pt semibold on the subheadline style.
        case headline
        /// 15 pt on the subheadline style.
        case body
        /// 12 pt on the caption style.
        case footnote
        /// 15 pt light on the subheadline style; SF Symbols next to text.
        case icon
        /// 15 pt bold on the subheadline style; the workout name being edited.
        case fieldTitle
        /// 17 pt on the body style; the title of a full-width action button.
        case button
        /// 28 pt bold on the title style; the title of a sheet such as the purchase screen. `title` is taken by
        /// `ActivityTypography`, and `.token(.title)` would be ambiguous.
        case sheetTitle

        fileprivate var textStyle: (swiftUI: Font.TextStyle, uiKit: UIFont.TextStyle) {
            switch self {
                case .headline, .body, .icon, .fieldTitle:
                    (.subheadline, .subheadline)
                case .footnote:
                    (.caption, .caption1)
                case .button:
                    (.body, .body)
                case .sheetTitle:
                    (.title, .title1)
            }
        }

        fileprivate var weight: (swiftUI: Font.Weight, uiKit: UIFont.Weight) {
            switch self {
                case .headline:
                    (.semibold, .semibold)
                case .icon:
                    (.light, .light)
                case .fieldTitle, .sheetTitle:
                    (.bold, .bold)
                case .body, .footnote, .button:
                    (.regular, .regular)
            }
        }
    }
}

extension Font {
    /// `.font(.token(.headline))`
    public static func token(_ style: DesignSystem.Token.Typography) -> Font {
        .system(style.textStyle.swiftUI, weight: style.weight.swiftUI)
    }
}

extension UIFont {
    @MainActor
    static func token(_ style: DesignSystem.Token.Typography) -> UIFont {
        let font = preferredFont(forTextStyle: style.textStyle.uiKit)
        guard style.weight.uiKit != .regular else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: style.weight.uiKit.rawValue],
        ])
        return UIFont(descriptor: descriptor, size: .zero)
    }
}
