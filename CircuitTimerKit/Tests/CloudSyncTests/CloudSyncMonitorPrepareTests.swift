@testable import CloudSync

import Dependencies
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CloudSyncMonitorPrepareTests {
    @Test
    func test_prepareDecision_waitsForItsInputsThenDecides() async {
        let inputs = InputsGate()
        let harness = MonitorHarness(prepareInputs: { await inputs.wait() })

        let preparing = Task { await harness.monitor.prepareDecision() }
        await inputs.untilWaiting()
        #expect(harness.preferenceReads.value == 0)

        inputs.open()
        await preparing.value

        #expect(harness.preferenceReads.value == 1)
        #expect(harness.monitor.mirroredContainer() == MonitorHarness.container)
    }

    @Test
    func test_subscriptions_neverDecide_statusArrivesWithTheDecisionOrAtOnceAfterIt() async {
        let harness = MonitorHarness()
        let early = harness.monitor.status()
        _ = harness.monitor.remoteChanges()
        #expect(harness.preferenceReads.value == 0)

        _ = harness.monitor.mirroredContainer()

        let decided = CloudSyncStatus(isRequested: true, isMirroring: nil, problem: nil)
        #expect(await early.next() == decided)
        #expect(await harness.monitor.status().next() == decided)
        #expect(harness.preferenceReads.value == 1)
    }

    @Test
    func test_prepareDecision_concurrentCallsShareOneWaitAndACancelledCallerNeverDecides() async {
        let inputs = InputsGate()
        let calls = LockIsolated(0)
        let harness = MonitorHarness(prepareInputs: {
            calls.withValue { $0 += 1 }
            await inputs.wait()
        })

        let cancelled = Task { await harness.monitor.prepareDecision() }
        let waiting = Task { await harness.monitor.prepareDecision() }
        await inputs.untilWaiting()
        cancelled.cancel()
        await Task.megaYield()
        #expect(harness.preferenceReads.value == 0)

        inputs.open()
        await cancelled.value
        await waiting.value
        await harness.monitor.prepareDecision()

        #expect(calls.value == 1)
        #expect(harness.preferenceReads.value == 1)
    }
}

/// The decision's inputs, held until the test opens them.
private final class InputsGate: Sendable {
    private let opened: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let waiters = LockIsolated(0)

    init() {
        (opened, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        waiters.withValue { $0 += 1 }
        for await _ in opened {
            return
        }
    }

    /// Returns once something waits on the gate.
    func untilWaiting() async {
        while waiters.value == 0 {
            await Task.yield()
        }
    }

    func open() {
        continuation.yield()
        continuation.finish()
    }
}
