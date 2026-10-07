import Foundation

extension Duration {
    public enum ClockTextStyle: Sendable {
        /// `00:01:15`; hours take two digits or more.
        case hoursMinutesSeconds
    }

    /// ASCII digits and colons in every region; fractions round down.
    public func clockText(_ style: ClockTextStyle) -> String {
        switch style {
            case .hoursMinutesSeconds:
                formatted(
                    TimeFormatStyle(
                        pattern: .hourMinuteSecond(padHourToLength: 2, roundFractionalSeconds: .down),
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                )
        }
    }
}
