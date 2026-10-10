import Foundation

extension Duration {
    public enum ClockTextStyle: Sendable {
        /// `00:01:15`; hours take two digits or more.
        case hoursMinutesSeconds
        /// `01:15`; minutes take two digits or more.
        case minutesSeconds
        /// `minutesSeconds` below an hour, `hoursMinutesSeconds` from an hour on.
        case adaptive
        /// `minutesSeconds` with fractions rounded up, so time left reads `00:00` only once none is left.
        case remaining
    }

    /// ASCII digits and colons in every region; fractions round down, except for `remaining`.
    public func clockText(_ style: ClockTextStyle) -> String {
        switch style {
            case .hoursMinutesSeconds:
                posixFormatted(.hourMinuteSecond(padHourToLength: 2, roundFractionalSeconds: .down))
            case .minutesSeconds:
                posixFormatted(.minuteSecond(padMinuteToLength: 2, roundFractionalSeconds: .down))
            case .adaptive:
                clockText(self < .seconds(3_600) ? .minutesSeconds : .hoursMinutesSeconds)
            case .remaining:
                posixFormatted(.minuteSecond(padMinuteToLength: 2, roundFractionalSeconds: .up))
        }
    }

    private func posixFormatted(_ pattern: TimeFormatStyle.Pattern) -> String {
        formatted(TimeFormatStyle(pattern: pattern, locale: Locale(identifier: "en_US_POSIX")))
    }
}
