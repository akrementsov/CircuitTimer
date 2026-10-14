@testable import WorkoutTimerFeature

import AVFAudio
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct CueDeactivationTests {
    @Test(arguments: [false, true])
    func test_end_deactivationFails_retriesOnlyOnce(persistent: Bool) async {
        let scheduler = DispatchQueue.test
        let attempts = LockIsolated(0)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: {},
                deactivate: {
                    let attempt = attempts.withValue {
                        $0 += 1
                        return $0
                    }
                    if attempt == 1 || persistent { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.end(owner: timerID) }
        #expect(attempts.value == 1)
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
        await scheduler.advance(by: .seconds(10))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
    }

    @Test
    func test_end_busyDeactivation_doesNotRetryInactiveSession() async {
        let scheduler = DispatchQueue.test
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { calls.withValue { $0.append(true) } },
                deactivate: {
                    calls.withValue { $0.append(false) }
                    throw NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.isBusy.rawValue)
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.end(owner: timerID) }
        await scheduler.advance(by: .seconds(10))
        await engine.perform { _ in }
        #expect(calls.value == [true, false])
        let nextOwner = UUID(fixture: 2)
        #expect(await engine.perform { $0.start(owner: nextOwner, revision: 1) } == .admitted)
        #expect(calls.value == [true, false, true])
    }

    @Test
    func test_preempt_pendingDeactivation_keepsCleanupDeadline() async {
        let scheduler = DispatchQueue.test
        let attempts = LockIsolated(0)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: {},
                deactivate: {
                    let attempt = attempts.withValue {
                        $0 += 1
                        return $0
                    }
                    if attempt == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(await engine.perform { $0.preempt(owner: timerID, revision: 2) })
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func test_newAdmission_activationUnavailable_keepsPendingDeactivation(preparing: Bool, skipped: Bool) async {
        let scheduler = DispatchQueue.test
        let activations = LockIsolated(0)
        let attempts = LockIsolated(0)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: {
                    let attempt = activations.withValue {
                        $0 += 1
                        return $0
                    }
                    if attempt > 1 {
                        let code = skipped ? AVAudioSession.ErrorCode.insufficientPriority.rawValue : -50
                        throw NSError(domain: NSOSStatusErrorDomain, code: code)
                    }
                },
                deactivate: {
                    let attempt = attempts.withValue {
                        $0 += 1
                        return $0
                    }
                    if attempt == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        if preparing {
            let result = await engine.perform { $0.prepare(owner: timerID, revision: 2) }
            #expect(result == CueResult(failures: skipped ? [] : [.sessionFailed(code: -50)]))
        } else {
            let result = await engine.perform { $0.start(owner: timerID, revision: 2) }
            #expect(result == (skipped ? .skipped : .failed(.sessionFailed(code: -50))))
        }
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
    }

    @Test
    func test_preempt_persistentDeactivationFailure_doesNotResetRetryBudget() async {
        let scheduler = DispatchQueue.test
        let attempts = LockIsolated(0)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: {},
                deactivate: {
                    attempts.withValue { $0 += 1 }
                    throw NSError(domain: NSOSStatusErrorDomain, code: -50)
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(await engine.perform { $0.preempt(owner: timerID, revision: 2) })
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
        #expect(await engine.perform { $0.preempt(owner: timerID, revision: 3) })
        await scheduler.advance(by: .seconds(2))
        await engine.perform { _ in }
        #expect(attempts.value == 2)
    }

    @Test
    func test_start_newCueAfterFailedDeactivation_invalidatesRetry() async {
        let scheduler = DispatchQueue.test
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { calls.withValue { $0.append(true) } },
                deactivate: {
                    calls.withValue { $0.append(false) }
                    throw NSError(domain: NSOSStatusErrorDomain, code: -50)
                }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        await scheduler.advance(by: .seconds(1))
        #expect(await engine.perform { $0.start(owner: timerID, revision: 2) } == .admitted)
        await scheduler.advance(by: .milliseconds(500))
        await engine.perform { _ in }
        #expect(calls.value == [true, false, true])
    }
}
