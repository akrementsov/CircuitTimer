import Foundation

extension Duration {
    public enum ClockTextStyle: Sendable {
        /// `00:01:15`; hours take two digits or more.
        case hoursMinutesSeconds
        /// `01:15`; minutes take two digits or more.
        case minutesSeconds
        /// `minutesSeconds` below an hour, `hoursMinutesSeconds` from an hour on.
        case adaptive
    }

    /// ASCII digits and colons in every region; fractions round down.
    public func clockText(_ style: ClockTextStyle) -> String {
        switch style {
            case .hoursMinutesSeconds:
                formatted(pattern: .hourMinuteSecond(padHourToLength: 2, roundFractionalSeconds: .down))
            case .minutesSeconds:
                formatted(pattern: .minuteSecond(padMinuteToLength: 2, roundFractionalSeconds: .down))
            case .adaptive:
                clockText(self < .seconds(3_600) ? .minutesSeconds : .hoursMinutesSeconds)
        }
    }

    private func formatted(pattern: TimeFormatStyle.Pattern) -> String {
        formatted(TimeFormatStyle(pattern: pattern, locale: Locale(identifier: "en_US_POSIX")))
    }
}
