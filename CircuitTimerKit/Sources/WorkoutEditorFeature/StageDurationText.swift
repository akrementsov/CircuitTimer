import DesignSystem
import Foundation
import WorkoutDomain

/// A stage duration typed on the number pad as MM:SS, as in the original app: up to four digits, the colon from
/// the third digit on, and the digits not typed filled with zeros on the right.
enum StageDurationText {
    static let maxDigits = 4

    /// The field's text after an edit, or `nil` when the edit brings more than four digits: a fifth digit or a long
    /// paste is rejected whole, and the field keeps what it had.
    static func masked(_ text: String) -> String? {
        let digits = digits(of: text)
        guard digits.count <= maxDigits else { return nil }
        guard digits.count > 2 else { return String(digits) }

        return String(digits.prefix(2)) + ":" + String(digits.dropFirst(2))
    }

    /// UIKit offsets count UTF-16 units; the mask keeps the caret after the same decimal digit even when it
    /// normalizes another script and moves the colon in a single edit. Deleting the colon leaves the caret before it.
    static func masked(_ text: String, caretOffset: Int) -> (text: String, caretOffset: Int)? {
        guard let accepted = masked(text) else { return nil }
        let prefix = String(decoding: text.utf16.prefix(caretOffset), as: UTF16.self)
        let count = digits(of: prefix).count
        let lastSymbol = prefix.last(where: { $0 == ":" || digit(of: $0) != nil })
        let followsColon = count > 2 || (count == 2 && lastSymbol == ":")
        return (accepted, min(count + (followsColon ? 1 : 0), accepted.utf16.count))
    }

    /// «1» is 10:00 and «123» is 12:30; seconds above 59 carry into the minutes, and the result stops at
    /// `WorkoutLimits.maxStageDuration`.
    static func duration(from text: String) -> Duration {
        let digits = digits(of: text).prefix(maxDigits)
        let padded = digits + String(repeating: "0", count: maxDigits - digits.count)
        guard let minutes = Int64(padded.prefix(2)), let seconds = Int64(padded.suffix(2)) else { return .zero }

        return min(.seconds(minutes * 60 + seconds), WorkoutLimits.maxStageDuration)
    }

    /// The text of a stored duration: empty for none, so the field shows its «00:00» placeholder. A stored fraction of
    /// a second plays, so it reads «00:00» as text rather than as the placeholder.
    static func text(for duration: Duration) -> String {
        let clamped = min(duration, WorkoutLimits.maxStageDuration)
        guard clamped > .zero else { return "" }

        return clamped.clockText(.minutesSeconds)
    }

    /// The digits of the text as ASCII, whatever script they were typed in: a number pad or a paste may bring
    /// Arabic-Indic or Devanagari digits. Only decimal digits count; «½», «³» or «Ⅳ» are dropped.
    private static func digits(of text: String) -> String {
        String(text.compactMap { digit(of: $0) })
    }

    private static func digit(of character: Character) -> Character? {
        guard
            character.unicodeScalars.count == 1,
            character.unicodeScalars.first?.properties.numericType == .decimal,
            let value = character.wholeNumberValue
        else { return nil }

        return Character(String(value))
    }
}
