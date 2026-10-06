import CoreGraphics

extension DesignSystem.Token {
    public enum Radius: CGFloat, Sendable, CaseIterable {
        case s = 8
        case m = 12
        case l = 24
    }
}

extension CGFloat {
    /// `RoundedRectangle(cornerRadius: .token(radius: .m))`
    public static func token(radius: DesignSystem.Token.Radius) -> CGFloat {
        radius.rawValue
    }
}
