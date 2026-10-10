import SwiftUI

extension DesignSystem.Token {
    public enum TextColor: Sendable, CaseIterable {
        case primary
        case secondary
        /// Text on a `brand` or stage fill.
        case onAccent
    }

    public enum SurfaceColor: Sendable, CaseIterable {
        case screen
        case card
        /// Rows that cannot be tapped, such as the app version.
        case cardInactive
        /// An input or a control inside a card, and the track of a progress bar.
        case field
        /// The `secondaryAction` asset: the field being edited.
        case focused
    }

    public enum StageColor: Sendable, CaseIterable {
        case work
        case rest
        /// The `surface(.card)` asset: the timer's dark stage card, for pauses, the start and the end.
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
            case .onAccent:
                Color("TextOnAccent", bundle: .module)
        }
    }

    /// `.background(.surface(.card))`
    public static func surface(_ color: DesignSystem.Token.SurfaceColor) -> Color {
        switch color {
            case .screen:
                Color("SurfaceScreen", bundle: .module)
            case .card:
                Color("SurfaceCard", bundle: .module)
            case .cardInactive:
                Color("SurfaceCardInactive", bundle: .module)
            case .field:
                Color("SurfaceField", bundle: .module)
            case .focused:
                Color("SecondaryAction", bundle: .module)
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

    /// A `brand` control that cannot act now, such as a stepper at its limit.
    public static var brandInactive: Color {
        Color("BrandInactive", bundle: .module)
    }

    /// The track of a switch that is on.
    public static var switchOn: Color {
        Color("SwitchOn", bundle: .module)
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
