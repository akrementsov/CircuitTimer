import CoreGraphics

extension DesignSystem.Token {
    public enum Size: CGFloat, Sendable, CaseIterable {
        /// Minimum height of a list row, and the height of a full-width action button.
        case row = 50
        /// Narrowest a row title gets before the content next to it moves under it.
        /// A base value at the default text size; scale it with `@ScaledMetric`.
        case rowTitleMinWidth = 100
        /// Side of a stage's intensity marker.
        case marker = 17
        /// Height of the timer's progress bar.
        case progressBar = 8
        /// Width of the outline of the timer's round buttons.
        case buttonBorder = 2
    }
}

extension CGFloat {
    /// `.frame(minHeight: .token(size: .row))`
    public static func token(size: DesignSystem.Token.Size) -> CGFloat {
        size.rawValue
    }
}
