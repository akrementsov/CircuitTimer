import SwiftUI
import UIKit

extension DesignSystem.Token {
    public enum TextColor: Sendable, CaseIterable {
        case primary
        case secondary
    }

    public enum SurfaceColor: Sendable, CaseIterable {
        case screen
        case card
        case grouped
    }

    public enum StageColor: Sendable, CaseIterable {
        case work
        case rest
        case pause
    }
}

// Text and surfaces follow the system palette; brand and stage colors come from the asset
// catalog, where each has a light and a dark variant.
extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.text(.secondary))`
    public static func text(_ color: DesignSystem.Token.TextColor) -> Color {
        switch color {
            case .primary:
                Color(uiColor: .label)
            case .secondary:
                Color(uiColor: .secondaryLabel)
        }
    }

    /// `.background(.surface(.card))`
    public static func surface(_ color: DesignSystem.Token.SurfaceColor) -> Color {
        switch color {
            case .screen:
                Color(uiColor: .systemBackground)
            case .card:
                Color(uiColor: .secondarySystemBackground)
            case .grouped:
                Color(uiColor: .systemGroupedBackground)
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
                Color("StagePause", bundle: .module)
        }
    }

    public static var brand: Color {
        Color("Brand", bundle: .module)
    }
}
