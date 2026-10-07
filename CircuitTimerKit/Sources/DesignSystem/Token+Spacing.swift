import CoreGraphics

extension DesignSystem.Token {
    public enum Spacing: CGFloat, Sendable, CaseIterable {
        case xxs = 4
        case xs = 8
        case s = 10
        case m = 12
        case l = 16
        case xl = 20
        case xxl = 24
        case xxxl = 32
    }
}

extension CGFloat {
    /// `.padding(.token(spacing: .m))`
    public static func token(spacing: DesignSystem.Token.Spacing) -> CGFloat {
        spacing.rawValue
    }
}
