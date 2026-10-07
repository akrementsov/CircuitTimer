@testable import DesignSystem

import SwiftUI
import Testing

@Suite
struct TypographyTokenTests {
    // `Font.resolve(in:)` exists from iOS 26; `make test` runs on it.
    @available(iOS 26, *)
    @Test(arguments: DesignSystem.Token.Typography.allCases)
    func test_fontToken_defaultDynamicType_matchesDesignSizeWeightAndScales(style: DesignSystem.Token.Typography) {
        let font = Font.token(style)
        let regular = font.resolve(in: Self.context(.large))
        let accessibility = font.resolve(in: Self.context(.xxxLarge))

        switch style {
            case .headline:
                #expect(regular.pointSize == 15)
                #expect(regular.weight == Self.resolvedWeight(.semibold))
            case .body:
                #expect(regular.pointSize == 15)
                #expect(regular.weight == Self.resolvedWeight(.regular))
            case .footnote:
                #expect(regular.pointSize == 12)
                #expect(regular.weight == Self.resolvedWeight(.regular))
            case .timerLarge:
                // Rounded design and monospaced digits are only visible on the resolved font as a whole,
                // so the expected font is written out as a system font.
                // swiftlint:disable:next no_literal_font
                let reference = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
                #expect(regular == reference.resolve(in: Self.context(.large)))
        }
        #expect(accessibility.pointSize > regular.pointSize)
    }

    // A resolved weight carries the Float rounding of the font engine, so the expected weight is
    // resolved the same way instead of compared with the `Font.Weight` constant.
    @available(iOS 26, *)
    private static func resolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        // The reference weight needs a font that carries exactly that weight.
        // swiftlint:disable:next no_literal_font
        Font.system(size: 15, weight: weight).resolve(in: context(.large)).weight
    }

    @available(iOS 26, *)
    private static func context(_ size: DynamicTypeSize) -> Font.Context {
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = size
        return environment.fontResolutionContext
    }
}
