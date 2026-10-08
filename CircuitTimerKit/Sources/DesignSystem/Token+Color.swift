import SwiftUI

extension DesignSystem.Token {
    public enum TextColor: Sendable, CaseIterable {
        case primary
        case secondary
    }

    public enum SurfaceColor: Sendable, CaseIterable {
        case screen
        case card
    }

    public enum StageColor: Sendable, CaseIterable {
        case work
        case rest
        /// The `surface(.card)` asset: it fills the full-screen timer and is never drawn on a card.
        case pause
    }
}

// All colors come from the asset catalog, one universal value each: the app is dark only.
extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.text(.secondary))`
    public static func text(_ color: DesignSystem.Token.TextColor) -> Color {
        switch color {
            case .primary:
                Color("TextPrimary", bundle: .module)
            case .secondary:
                Color("TextSecondary", bundle: .module)
        }
    }

    /// `.background(.surface(.card))`
    public static func surface(_ color: DesignSystem.Token.SurfaceColor) -> Color {
        switch color {
            case .screen:
                Color("SurfaceScreen", bundle: .module)
            case .card:
                Color("SurfaceCard", bundle: .module)
        }
    }

    /// `.foregroundStyle(.stage(.work))`
    public static func stage(_ color: DesignSystem.Token.StageColor) -> Color {
        switch color {
            case .work:
                Color("StageWork", bundle: .module)
            case .rest:
                Color("StageRest", bundle: .module)
            case .pause:
                Color("SurfaceCard", bundle: .module)
        }
    }

    public static var brand: Color {
        Color("Brand", bundle: .module)
    }

    /// Destructive actions.
    public static var danger: Color {
        Color("Danger", bundle: .module)
    }

    /// Fill of non-destructive actions next to `danger` ones; white glyphs stay readable on it.
    public static var secondaryAction: Color {
        Color("SecondaryAction", bundle: .module)
    }
}
