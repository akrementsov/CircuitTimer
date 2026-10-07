import CoreGraphics

extension DesignSystem.Token {
    public enum Radius: CGFloat, Sendable, CaseIterable {
        case xs = 5
        case s = 8
        case m = 10
        case l = 25
    }
}

extension CGFloat {
    /// `RoundedRectangle(cornerRadius: .token(radius: .m))`
    public static func token(radius: DesignSystem.Token.Radius) -> CGFloat {
        radius.rawValue
    }
}
