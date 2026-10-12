@testable import DesignSystem

import CoreGraphics
import Testing

@Suite
struct SwipeRevealTests {
    private static let reveal = SwipeReveal(groupWidth: 100)
    private static var width: CGFloat { reveal.revealWidth }

    @Test
    func test_revealWidth_group_addsTheGapToTheRow() {
        #expect(Self.width == 100 + .token(spacing: .l))
    }

    @Test(arguments: [
        (CGFloat(20), CGFloat.zero),
        (.zero, .zero),
        (-30, -30),
        (-width, -width),
        (-width - 30, -width - 10),
    ])
    func test_offset_closedRow_followsALeftDragAndSlowsPastOpen(translation: CGFloat, expected: CGFloat) {
        #expect(Self.reveal.offset(translation: translation, startsOpen: false) == expected)
    }

    @Test(arguments: [
        (CGFloat.zero, -width),
        (30, -width + 30),
        (width, .zero),
        (width + 50, .zero),
        (-30, -width - 10),
    ])
    func test_offset_openRow_closesWithARightDragAndStopsAtItsPlace(translation: CGFloat, expected: CGFloat) {
        #expect(Self.reveal.offset(translation: translation, startsOpen: true) == expected)
    }

    @Test(arguments: [
        (-width / 2, false, false),
        (-width / 2 - 1, false, true),
        (-width, false, true),
        (width / 4, true, true),
        (width, true, false),
    ])
    func test_settlesOpen_predictedEnd_opensPastHalfThePlaques(predicted: CGFloat, startsOpen: Bool, expected: Bool) {
        #expect(Self.reveal.settlesOpen(predictedEndTranslation: predicted, startsOpen: startsOpen) == expected)
    }

    @Test(arguments: [
        (CGSize(width: 10, height: 5), SwipeAxis.horizontal),
        (CGSize(width: -10, height: 5), .horizontal),
        (CGSize(width: 5, height: 10), .vertical),
        (CGSize(width: 5, height: -5), .vertical),
        (CGSize.zero, .vertical),
    ])
    func test_swipeAxis_translation_isHorizontalOnlyWhenWider(translation: CGSize, expected: SwipeAxis) {
        #expect(SwipeAxis(translation: translation) == expected)
    }
}
