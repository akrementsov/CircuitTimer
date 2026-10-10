@testable import DesignSystem

import CoreGraphics
import CoreText
import Testing

@Suite
struct StageClockTextTests {
    @Test
    func test_fontSize_wideShortBox_isBoundByCapHeight() throws {
        let metrics = try Self.systemMetrics()

        let size = metrics.fontSize(fitting: CGSize(width: 10_000, height: 50))

        #expect(size == 50 / metrics.capHeight)
    }

    @Test
    func test_fontSize_narrowTallBox_isBoundByWidthWithMargin() throws {
        let metrics = try Self.systemMetrics()

        let size = metrics.fontSize(fitting: CGSize(width: 100, height: 10_000))

        #expect(size == 100 / (metrics.anchoredWidth * 1.03))
    }

    @Test(arguments: [
        CGSize.zero,
        CGSize(width: 0, height: 50),
        CGSize(width: 100, height: 0),
        CGSize(width: -100, height: 50),
        CGSize(width: 100, height: -50),
    ])
    func test_fontSize_emptyOrNegativeBox_isZero(box: CGSize) throws {
        let metrics = try Self.systemMetrics()

        #expect(metrics.fontSize(fitting: box) == 0)
    }

    @Test
    func test_faceCurrent_bundledFont_isLeagueGothicWithOwnMetrics() {
        #expect(StageClockText.Face.current == .leagueGothic)
        #expect(StageClockText.Face.leagueGothic.metrics != StageClockText.Face.system.metrics)
    }

    @Test
    func test_metricsForPostScriptName_nameCoreTextSubstitutes_isNil() {
        #expect(StageClockText.Face.metrics(forPostScriptName: "CircuitTimer-NoSuchFont", isAvailable: true) == nil)
    }

    @Test(arguments: [
        ("01:15", "01:01"),
        ("123:45", "123:123"),
        ("3", "3"),
    ])
    @MainActor
    func test_template_text_repeatsMinutes(text: String, expected: String) {
        #expect(StageClockText.template(for: text) == expected)
    }

    // Any real font will do: the sizing arithmetic does not depend on the face.
    private static func systemMetrics() throws -> ClockFaceMetrics {
        let metrics = try ClockFaceMetrics(font: #require(CTFontCreateUIFontForLanguage(.system, 100, nil)))
        try #require(metrics.capHeight > 0)
        try #require(metrics.anchoredWidth > 0)
        return metrics
    }
}
