@testable import DesignSystem

import SwiftUI
import Testing

@Suite
struct WatchTypographyTokenTests {
    // The package tests run on the iPhone simulator, so the text styles resolve to their iOS sizes; on the watch the
    // same styles are smaller. `WatchTypography` is not `CaseIterable`: a new case needs a line here as well.
    @available(iOS 26, *)
    @Test(arguments: [
        DesignSystem.Token.WatchTypography.runningStageClock,
        .runningStageClockCompact,
        .runningStageName,
        .nextStageName,
        .screenTitle,
        .rowTitle,
        .rowDetail,
        .note,
        .control,
    ])
    func test_watchFontToken_defaultAndAccessibilitySize_matchesDesignSizeWeightAndScaling(
        style: DesignSystem.Token.WatchTypography
    ) {
        let font = Font.token(style)
        let regular = font.resolve(in: Self.context(.large))
        let accessibility = font.resolve(in: Self.context(.xxxLarge))

        switch style {
            case .runningStageClock:
                #expect(regular.pointSize == 56)
                #expect(accessibility.pointSize == regular.pointSize)
            case .runningStageClockCompact:
                #expect(regular.pointSize == 48)
                #expect(accessibility.pointSize == regular.pointSize)
            case .runningStageName:
                Self.expectText(regular, accessibility, size: 17, weight: .heavy)
            case .nextStageName:
                Self.expectText(regular, accessibility, size: 13, weight: .bold)
            case .screenTitle:
                Self.expectText(regular, accessibility, size: 17, weight: .semibold)
            case .rowTitle, .control:
                Self.expectText(regular, accessibility, size: 17, weight: .semibold)
            case .rowDetail, .note:
                Self.expectText(regular, accessibility, size: 13, weight: .regular)
        }
    }

    @available(iOS 26, *)
    private static func expectText(
        _ regular: Font.Resolved,
        _ accessibility: Font.Resolved,
        size: CGFloat,
        weight: Font.Weight,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(regular.pointSize == size, sourceLocation: sourceLocation)
        #expect(regular.weight == resolvedWeight(weight), sourceLocation: sourceLocation)
        #expect(accessibility.pointSize > regular.pointSize, sourceLocation: sourceLocation)
    }

    // A resolved weight carries the Float rounding of the font engine, so the expected weight is resolved the same
    // way instead of compared with the `Font.Weight` constant.
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
