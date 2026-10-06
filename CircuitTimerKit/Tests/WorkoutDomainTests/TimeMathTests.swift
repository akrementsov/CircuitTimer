@testable import WorkoutDomain

import Foundation
import Testing

@Suite
struct TimeMathTests {
    private static let saturationSeconds = Int64.max / 1_000

    @Test(arguments: [
        (Duration.zero, Duration.zero),
        (.seconds(-1), .zero),
        (.nanoseconds(999_999), .zero),
        (.microseconds(1), .zero),
        (.milliseconds(1) + .nanoseconds(999_999), .milliseconds(1)),
        (.milliseconds(1_500), .milliseconds(1_500)),
        (.seconds(saturationSeconds - 1), .milliseconds((saturationSeconds - 1) * 1_000)),
        (.seconds(saturationSeconds), .milliseconds(Int64.max)),
        (.seconds(Int64.max), .milliseconds(Int64.max)),
    ])
    func test_flooredToMilliseconds_truncatesAndSaturates(input: Duration, expected: Duration) {
        #expect(input.flooredToMilliseconds() == expected)
    }

    @Test(arguments: [
        (moment(0), moment(1), Duration.zero),
        (moment(1), moment(1), .zero),
        (moment(1.001), moment(1), .milliseconds(1)),
        (moment(1.0009), moment(1), .zero),
        // Within the 1 µs tolerance a hair below the boundary counts as the boundary.
        (moment(1.0009995), moment(1), .milliseconds(1)),
        (moment(1.000998), moment(1), .zero),
        (moment(2e10), origin, .milliseconds(10_000_000_000_000)),
        (Date(timeIntervalSinceReferenceDate: .infinity), origin, .zero),
        (Date(timeIntervalSinceReferenceDate: .nan), origin, .zero),
    ])
    func test_elapsedSince_returnsWholeMillisecondsAndZeroForInvalidIntervals(now: Date, start: Date, expected: Duration) {
        #expect(now.elapsed(since: start) == expected)
    }

    @Test
    func test_addingThenElapsed_currentEpoch_roundTripsWholeMilliseconds() {
        var generator = SeededGenerator(seed: 0x7173)
        for _ in 0..<10_000 {
            let start = origin.addingTimeInterval(Double.random(in: 0...86_400_000, using: &generator))
            let duration = Duration.milliseconds(Int64.random(in: 1...6_000_000, using: &generator))

            #expect(start.adding(duration).elapsed(since: start) == duration, "start \(start), duration \(duration)")
        }
    }
}
