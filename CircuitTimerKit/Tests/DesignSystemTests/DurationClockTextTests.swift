@testable import DesignSystem

import Foundation
import Testing

@Suite
struct DurationClockTextTests {
    @Test(arguments: [
        (Duration.zero, "00:00:00"),
        (.seconds(75), "00:01:15"),
        (.seconds(3_599), "00:59:59"),
        (.seconds(3_600), "01:00:00"),
        (.seconds(36_000), "10:00:00"),
        (.seconds(360_000), "100:00:00"),
        // The longest workout the limits allow: 50 stages of 99:59 in each section, training repeated 99 times.
        (.seconds(50 * 5_999 * (99 + 2)), "8415:15:50"),
        (.milliseconds(1_999), "00:00:01"),
        (.milliseconds(59_999), "00:00:59"),
    ])
    func test_clockText_hoursMinutesSeconds_formatsDurations(duration: Duration, expected: String) {
        #expect(duration.clockText(.hoursMinutesSeconds) == expected)
    }

    @Test(arguments: [
        (Duration.zero, "00:00"),
        (.seconds(75), "01:15"),
        (.seconds(3_599), "59:59"),
        // A stage can be longer than an hour; its minutes keep counting instead of turning into hours.
        (.seconds(3_600), "60:00"),
        (.seconds(5_999), "99:59"),
        (.milliseconds(999), "00:00"),
        (.milliseconds(59_999), "00:59"),
    ])
    func test_clockText_minutesSeconds_formatsDurations(duration: Duration, expected: String) {
        #expect(duration.clockText(.minutesSeconds) == expected)
    }

    @Test(arguments: [
        (Duration.seconds(75), "01:15"),
        (.milliseconds(3_599_999), "59:59"),
        (.seconds(3_600), "01:00:00"),
    ])
    func test_clockText_adaptive_switchesFormAtOneHour(duration: Duration, expected: String) {
        #expect(duration.clockText(.adaptive) == expected)
    }
}
