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
    /// Arabic-Indic or Devanagari digits. Fractions such as «½» are not digits and are dropped.
    private static func digits(of text: String) -> String {
        String(text.compactMap { character in
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }

            return Character(String(value))
        })
    }
}
