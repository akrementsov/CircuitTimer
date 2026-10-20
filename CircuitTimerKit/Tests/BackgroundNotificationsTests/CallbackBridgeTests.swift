@testable import BackgroundNotifications

import Dependencies
import Foundation
import Testing

struct CallbackBridgeTests {
    @Test
    func test_wait_cancelled_throwsCancellationError() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock<Duration>()
            let bridge = CallbackBridge<Int>()
            let task = Task { try await bridge.wait(timeout: .seconds(2), clock: clock) }
            await #expect(throws: (any Error).self) { try await clock.checkSuspension() }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            try await clock.checkSuspension()
            await clock.advance(by: .seconds(2))
            bridge.resolve(.success(1))
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test
    func test_resolve_repeatedCallback_keepsFirstValue() async throws {
        let bridge = CallbackBridge<Int>()
        bridge.resolve(.success(1))
        bridge.resolve(.success(2))
        let value = try await bridge.wait(timeout: .seconds(2), clock: TestClock<Duration>())
        #expect(value == 1)
    }

    @Test
    func test_wait_noCallback_timesOutOnInjectedClock() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock<Duration>()
            let bridge = CallbackBridge<Int>()
            let task = Task { try await bridge.wait(timeout: .milliseconds(500), clock: clock) }
            defer { task.cancel() }
            try await #require(throws: SuspensionError.self) { try await clock.checkSuspension() }
            await clock.advance(by: .milliseconds(500))
            await #expect(throws: NotificationFailure.timedOut) { try await task.value }
            bridge.resolve(.success(3))
        }
    }
}
