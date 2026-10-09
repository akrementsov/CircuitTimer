@testable import DesignSystem

import SwiftUI
import Testing

@Suite
struct ColorTokenTests {
    @Test(arguments: ColorToken.all, ColorScheme.allCases)
    func test_colorTokens_lightAndDarkScheme_resolveToPalette(token: ColorToken, scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme

        let resolved = token.color.resolve(in: environment)

        // A missing asset resolves to clear, so the opacity also catches a wrong asset name.
        #expect(resolved.opacity == 1)
        #expect(abs(resolved.red - token.expected.red) < Self.tolerance)
        #expect(abs(resolved.green - token.expected.green) < Self.tolerance)
        #expect(abs(resolved.blue - token.expected.blue) < Self.tolerance)
    }

    private static let tolerance: Float = 0.002
}

enum ColorToken: Sendable, CustomTestStringConvertible {
    case text(DesignSystem.Token.TextColor)
    case surface(DesignSystem.Token.SurfaceColor)
    case stage(DesignSystem.Token.StageColor)
    case brand
    case brandInactive
    case switchOn
    case danger
    case secondaryAction

    static let all: [ColorToken] = DesignSystem.Token.TextColor.allCases.map(ColorToken.text)
        + DesignSystem.Token.SurfaceColor.allCases.map(ColorToken.surface)
        + DesignSystem.Token.StageColor.allCases.map(ColorToken.stage)
        + [.brand, .brandInactive, .switchOn, .danger, .secondaryAction]

    var color: Color {
        switch self {
            case let .text(color):
                .text(color)
            case let .surface(color):
                .surface(color)
            case let .stage(color):
                .stage(color)
            case .brand:
                .brand
            case .brandInactive:
                .brandInactive
            case .switchOn:
                .switchOn
            case .danger:
                .danger
            case .secondaryAction:
                .secondaryAction
        }
    }

    // Exhaustive on purpose: a new token does not compile until it has an expected value.
    var expected: Palette.Value {
        switch self {
            case .text(.primary):
                Palette.white
            case .text(.secondary):
                Palette.gray
            case .text(.onAccent):
                Palette.black
            case .surface(.screen):
                Palette.screen
            case .surface(.card), .stage(.pause):
                Palette.card
            case .surface(.cardInactive):
                Palette.cardInactive
            case .surface(.field):
                Palette.field
            case .stage(.work), .brand:
                Palette.accent
            case .brandInactive:
                Palette.accentInactive
            case .stage(.rest):
                Palette.cyan
            case .switchOn:
                Palette.green
            case .danger:
                Palette.danger
            case .surface(.focused), .secondaryAction:
                Palette.secondaryAction
        }
    }

    var testDescription: String {
        switch self {
            case let .text(color):
                "text(.\(color))"
            case let .surface(color):
                "surface(.\(color))"
            case let .stage(color):
                "stage(.\(color))"
            case .brand:
                "brand"
            case .brandInactive:
                "brandInactive"
            case .switchOn:
                "switchOn"
            case .danger:
                "danger"
            case .secondaryAction:
                "secondaryAction"
        }
    }
}

enum Palette {
    struct Value {
        let red: Float
        let green: Float
        let blue: Float
    }

    static let white = Value(red: 1, green: 1, blue: 1)
    static let black = Value(red: 0, green: 0, blue: 0)
    static let gray = Value(red: 0.596, green: 0.596, blue: 0.624)
    static let screen = Value(red: 0.110, green: 0.110, blue: 0.122)
    static let card = Value(red: 0.173, green: 0.173, blue: 0.188)
    static let cardInactive = Value(red: 0.145, green: 0.145, blue: 0.161)
    static let field = Value(red: 0.208, green: 0.208, blue: 0.224)
    static let accent = Value(red: 0.906, green: 0.996, blue: 0.329)
    static let accentInactive = Value(red: 0.498, green: 0.533, blue: 0.282)
    static let cyan = Value(red: 0.400, green: 0.929, blue: 1)
    static let green = Value(red: 0.188, green: 0.820, blue: 0.345)
    static let danger = Value(red: 1, green: 0.118, blue: 0.118)
    static let secondaryAction = Value(red: 0.286, green: 0.286, blue: 0.310)
}
