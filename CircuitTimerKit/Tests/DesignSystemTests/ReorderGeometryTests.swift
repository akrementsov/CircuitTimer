@testable import DesignSystem

import CoreGraphics
import Testing

@Suite
struct ReorderGeometryTests {
    /// Rows 40, 60 and 50 high, 10 apart: tops at 0, 50 and 120, middles at 20, 80 and 145.
    private static let heights: [CGFloat] = [40, 60, 50]

    @Test(arguments: [
        (0, 2, 3),
        (2, 0, 0),
        (1, 1, 1),
        (0, 1, 2),
    ])
    func test_moveOffset_downUpOrInPlace_countsPlacesBeforeRemoval(from: Int, destination: Int, expected: Int) {
        #expect(ReorderGeometry.moveOffset(from: from, destination: destination) == expected)
    }

    @Test(arguments: [
        (CGFloat.zero, 0),
        (40, 0),
        (41, 1),
        (105, 1),
        (106, 2),
        (500, 2),
    ])
    func test_destination_liftedFirstRowMovedDown_passesAtNeighbourMiddles(offset: CGFloat, expected: Int) {
        let geometry = ReorderGeometry(heights: Self.heights, from: 0, spacing: 10)

        #expect(geometry.destination(for: offset) == expected)
    }

    @Test(arguments: [
        (CGFloat.zero, 2),
        (-40, 2),
        (-41, 1),
        (-100, 1),
        (-101, 0),
        (-500, 0),
    ])
    func test_destination_liftedLastRowMovedUp_passesAtNeighbourMiddles(offset: CGFloat, expected: Int) {
        let geometry = ReorderGeometry(heights: Self.heights, from: 2, spacing: 10)

        #expect(geometry.destination(for: offset) == expected)
    }

    @Test
    func test_destination_noSpacing_usesRowHeightsAlone() {
        // Tops at 0, 40 and 100: the second row's middle is at 70.
        let geometry = ReorderGeometry(heights: Self.heights, from: 0)

        #expect(geometry.destination(for: 30) == 0)
        #expect(geometry.destination(for: 31) == 1)
    }

    @Test
    func test_shift_movedDown_rowsBetweenMoveUpByTheLiftedRow() {
        let geometry = ReorderGeometry(heights: Self.heights, from: 0, spacing: 10)

        #expect(geometry.shift(ofRowAt: 0, destination: 2) == 0)
        #expect(geometry.shift(ofRowAt: 1, destination: 2) == -50)
        #expect(geometry.shift(ofRowAt: 2, destination: 2) == -50)
        #expect(geometry.shift(ofRowAt: 2, destination: 1) == 0)
    }

    @Test
    func test_shift_movedUp_rowsBetweenMoveDownByTheLiftedRow() {
        let geometry = ReorderGeometry(heights: Self.heights, from: 2, spacing: 10)

        #expect(geometry.shift(ofRowAt: 0, destination: 0) == 60)
        #expect(geometry.shift(ofRowAt: 1, destination: 0) == 60)
        #expect(geometry.shift(ofRowAt: 2, destination: 0) == 0)
        #expect(geometry.shift(ofRowAt: 0, destination: 1) == 0)
    }

    @Test
    func test_shift_inPlace_movesNothing() {
        let geometry = ReorderGeometry(heights: Self.heights, from: 1, spacing: 10)

        #expect((0..<3).allSatisfy { geometry.shift(ofRowAt: $0, destination: 1) == 0 })
    }

    @Test(arguments: [
        (0, CGFloat.zero...130),
        (1, -50...60),
        (2, -120...0),
    ])
    func test_offsetRange_eachRow_keepsTheRowAmongItsRows(from: Int, expected: ClosedRange<CGFloat>) {
        #expect(ReorderGeometry(heights: Self.heights, from: from, spacing: 10).offsetRange == expected)
    }

    @Test
    func test_offsetRange_singleRow_isEmpty() {
        #expect(ReorderGeometry(heights: [40], from: 0, spacing: 10).offsetRange == 0...0)
    }

    @Test(arguments: [
        (CGFloat(10), CGFloat(10)),
        (200, 60),
        (-200, -50),
    ])
    func test_clampedOffset_insideOrBeyondTheRange_staysWithinIt(offset: CGFloat, expected: CGFloat) {
        #expect(ReorderGeometry(heights: Self.heights, from: 1, spacing: 10).clampedOffset(offset) == expected)
    }
}
