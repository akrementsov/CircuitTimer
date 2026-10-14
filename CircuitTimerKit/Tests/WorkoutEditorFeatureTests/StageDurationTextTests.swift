@testable import WorkoutEditorFeature

import Testing

@Suite
struct StageDurationTextTests {
    @Test(arguments: [
        ("", ""),
        ("12", "12"),
        ("123", "12:3"),
        ("١٢٣٤", "12:34"),
        ("𝟙𝟚𝟛𝟜", "12:34"),
        ("½³Ⅳ１２", "12"),
        ("12345", nil),
    ] as [(String, String?)])
    func test_masked_decimalDigits_normalizesAndRejectsOversizedPaste(input: String, expected: String?) {
        #expect(StageDurationText.masked(input) == expected)
    }

    @Test(arguments: [
        ("1", Duration.seconds(600)),
        ("123", .seconds(750)),
        ("12:34", .seconds(754)),
        ("1:30", .seconds(780)),
        ("0099", .seconds(99)),
        ("99:99", .seconds(5_999)),
        ("١٢٣٤", .seconds(754)),
        ("½³Ⅳ12", .seconds(720)),
    ])
    func test_duration_partialAndCarriedSeconds_padsRightNormalizesAndClamps(input: String, expected: Duration) {
        #expect(StageDurationText.duration(from: input) == expected)
    }

    @Test(arguments: [
        (Duration.zero, ""),
        (.milliseconds(500), "00:00"),
        (.seconds(6_000), "99:59"),
    ])
    func test_text_zeroFractionAndOverflow_preservesFractionAsTextAndClamps(duration: Duration, expected: String) {
        #expect(StageDurationText.text(for: duration) == expected)
    }

    @Test
    func test_masked_normalizedDigitAndMovedColon_keepsCaretAfterInsertedDigit() throws {
        let edit = try #require(StageDurationText.masked("1٤2:3", caretOffset: 2))

        #expect(edit.text == "14:23")
        #expect(edit.caretOffset == 2)
    }

    @Test
    func test_masked_thirdDigit_includesInsertedColonBeforeCaret() throws {
        let edit = try #require(StageDurationText.masked("123", caretOffset: 3))

        #expect(edit.text == "12:3")
        #expect(edit.caretOffset == 4)
    }

    @Test
    func test_masked_deletedFirstSecondsDigit_keepsCaretAfterExistingColon() throws {
        let edit = try #require(StageDurationText.masked("12:4", caretOffset: 3))

        #expect(edit.text == "12:4")
        #expect(edit.caretOffset == 3)
    }

    @Test
    func test_masked_deletedColon_keepsCaretBeforeRestoredColon() throws {
        let edit = try #require(StageDurationText.masked("0100", caretOffset: 2))

        #expect(edit.text == "01:00")
        #expect(edit.caretOffset == 2)
    }
}
