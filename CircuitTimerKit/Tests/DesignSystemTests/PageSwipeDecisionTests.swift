@testable import DesignSystem

import CoreGraphics
import Testing

@Suite
struct PageSwipeDecisionTests {
    @Test(arguments: [
        (CGSize(width: -200, height: 0), .forward),
        (CGSize(width: 200, height: 0), .backward),
        (CGSize(width: -101, height: 40), .forward),
        (CGSize(width: 101, height: -40), .backward),
    ] as [(CGSize, PageSwipeDirection?)])
    func test_direction_farSideways_turnsAgainstTheFinger(predictedEnd: CGSize, expected: PageSwipeDirection?) {
        #expect(PageSwipeDecision.direction(predictedEnd: predictedEnd, width: 300) == expected)
    }

    @Test(arguments: [
        (CGSize(width: -100, height: 0), 300),
        (CGSize(width: 100, height: 0), 300),
        (CGSize(width: -60, height: 0), 300),
        (CGSize(width: -200, height: 200), 300),
        (CGSize(width: 150, height: -250), 300),
        (CGSize(width: -200, height: 0), 0),
    ] as [(CGSize, CGFloat)])
    func test_direction_shortVerticalOrNoWidth_isNil(predictedEnd: CGSize, width: CGFloat) {
        #expect(PageSwipeDecision.direction(predictedEnd: predictedEnd, width: width) == nil)
    }

    @Test(arguments: [
        (CGFloat(40), CGFloat(400), CGFloat(140)),
        (-30, -200, -80),
        (50, -200, 0),
        (0, 0, 0),
    ])
    func test_predictedEnd_translationAndVelocity_addsAQuarterSecondOfTravel(
        translation: CGFloat,
        velocity: CGFloat,
        expected: CGFloat
    ) {
        #expect(PanProjection.predictedEnd(translation: translation, velocity: velocity) == expected)
    }
}
