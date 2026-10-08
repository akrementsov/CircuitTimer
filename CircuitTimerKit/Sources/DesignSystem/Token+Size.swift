import CoreGraphics

extension DesignSystem.Token {
    public enum Size: CGFloat, Sendable, CaseIterable {
        /// Minimum height of a list row.
        case row = 50
        /// Narrowest a row title gets before the content next to it moves under it.
        /// A base value at the default text size; scale it with `@ScaledMetric`.
        case rowTitleMinWidth = 100
    }
}

extension CGFloat {
    /// `.frame(minHeight: .token(size: .row))`
    public static func token(size: DesignSystem.Token.Size) -> CGFloat {
        size.rawValue
    }
}
