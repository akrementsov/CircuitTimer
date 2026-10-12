@testable import DesignSystem

import CoreGraphics
import Testing

@Suite
struct EdgeAutoScrollTests {
    private static let depth: CGFloat = .token(size: .row)
    private static let visibleRect = CGRect(x: 0, y: 100, width: 400, height: 600)
    private static let step = EdgeAutoScroll.maxStep / 4

    @Test(arguments: [
        (CGFloat(400), visibleRect),
        (visibleRect.minY + depth, visibleRect),
        (visibleRect.maxY - depth, visibleRect),
        (CGFloat(100), CGRect(x: 0, y: 100, width: 400, height: depth * 2)),
    ])
    func test_velocity_outsideTheZonesOrAShortArea_isZero(fingerY: CGFloat, visibleRect: CGRect) {
        #expect(EdgeAutoScroll.velocity(fingerY: fingerY, visibleRect: visibleRect) == 0)
    }

    @Test(arguments: [
        (0.1, 1),
        (0.2, 1),
        (0.4, 2),
        (0.6, 3),
        (0.9, 4),
        (1, 4),
        (2, 4),
    ])
    func test_velocity_deeperIntoAZone_scrollsFasterInSteps(fraction: CGFloat, level: CGFloat) {
        let intoTop = Self.visibleRect.minY + Self.depth - Self.depth * fraction
        let intoBottom = Self.visibleRect.maxY - Self.depth + Self.depth * fraction

        #expect(EdgeAutoScroll.velocity(fingerY: intoTop, visibleRect: Self.visibleRect) == -Self.step * level)
        #expect(EdgeAutoScroll.velocity(fingerY: intoBottom, visibleRect: Self.visibleRect) == Self.step * level)
    }
}
