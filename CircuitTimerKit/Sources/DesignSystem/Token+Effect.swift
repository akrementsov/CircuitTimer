import CoreGraphics

extension DesignSystem.Token {
    public enum Opacity: Double, Sendable, CaseIterable {
        /// A pressed button dims a little, like a system button's highlight.
        case pressed = 0.8
        /// The original button's shadow: the screen color at half opacity.
        case buttonShadow = 0.5
    }

    public enum ShadowRadius: CGFloat, Sendable, CaseIterable {
        /// The shadow of a full-width action button before iOS 26.
        case button = 5
    }
}

extension Double {
    /// `.opacity(.token(opacity: .pressed))`
    public static func token(opacity: DesignSystem.Token.Opacity) -> Double {
        opacity.rawValue
    }
}

extension CGFloat {
    /// `.shadow(color: …, radius: .token(shadowRadius: .button))`
    public static func token(shadowRadius: DesignSystem.Token.ShadowRadius) -> CGFloat {
        shadowRadius.rawValue
    }
}
