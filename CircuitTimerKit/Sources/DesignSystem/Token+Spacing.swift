import CoreGraphics

extension DesignSystem.Token {
    public enum Spacing: CGFloat, Sendable, CaseIterable {
        case xxs = 4
        case xs = 8
        case s = 12
        case m = 16
        case l = 24
        case xl = 32
    }
}

extension CGFloat {
    /// `.padding(.token(spacing: .m))`
    public static func token(spacing: DesignSystem.Token.Spacing) -> CGFloat {
        spacing.rawValue
    }
}
