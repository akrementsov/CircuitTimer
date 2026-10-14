@testable import WorkoutTimerFeature

import Testing

struct OutputWaiterTests {
    @Test
    func test_wait_completionBeforeRegistration_returnsFirstResult() async {
        let waiter = OutputWaiter()
        waiter.finish(.completed)
        waiter.finish(.failed)
        #expect(await waiter.wait() == .completed)
    }

    @Test
    func test_wait_taskCancelledBeforeCompletion_returnsCancellation() async {
        let waiter = OutputWaiter()
        let task = Task { await waiter.wait() }
        task.cancel()
        #expect(await task.value == .cancelled)
        waiter.finish(.completed)
        #expect(await waiter.wait() == .cancelled)
    }
}
