@testable import BackgroundNotifications

import Dependencies
import Foundation
import Testing

struct CallbackBridgeTests {
    @Test
    func test_wait_cancelled_throwsCancellationError() async throws {
        let bridge = CallbackBridge<Int>()
        let task = Task { try await bridge.wait(timeout: .seconds(2), clock: TestClock<Duration>()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
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
        let clock = TestClock()
        let bridge = CallbackBridge<Int>()
        let task = Task { try await bridge.wait(timeout: .milliseconds(500), clock: clock) }
        await clock.advance(by: .milliseconds(500))
        await #expect(throws: NotificationFailure.timedOut) { try await task.value }
        bridge.resolve(.success(3))
    }
}
