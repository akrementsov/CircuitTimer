@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct CueEngineTests {
    @Test
    func test_suspend_beforeFirstAdmission_rejectsSuspendedRevision() async {
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(session: CueAudioSession(
            activate: { calls.withValue { $0.append(true) } },
            deactivate: { calls.withValue { $0.append(false) } }
        ), idleScheduler: DispatchQueue.test.eraseToAnyScheduler())
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(await engine.perform { $0.start(owner: timerID, revision: 1) } == .rejected)
        #expect(calls.value.isEmpty)
        #expect(await engine.perform { $0.start(owner: timerID, revision: 2) } == .admitted)
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_start_closedOwner_rejectsLateBurst() async {
        let engine = CueEngine(
            session: CueAudioSession(activate: {}, deactivate: {}),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler()
        )
        await engine.perform { $0.end(owner: timerID) }
        let result = await engine.perform { $0.start(owner: timerID, revision: 1) }
        #expect(result == .rejected)
    }

    @Test
    func test_suspend_staleRevision_doesNotDeactivateNewBurst() async {
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(session: CueAudioSession(
            activate: { calls.withValue { $0.append(true) } },
            deactivate: { calls.withValue { $0.append(false) } }
        ), idleScheduler: DispatchQueue.test.eraseToAnyScheduler())
        _ = await engine.perform { $0.start(owner: timerID, revision: 2) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(calls.value == [true])
        #expect(await engine.perform { $0.start(owner: timerID, revision: 1) } == .rejected)
        await engine.perform { $0.end(owner: timerID) }
        #expect(calls.value == [true, false])
    }

    @Test
    func test_start_idleWithoutOutput_deactivatesAfterDeadline() async {
        let scheduler = DispatchQueue.test
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { calls.withValue { $0.append(true) } },
                deactivate: { calls.withValue { $0.append(false) } }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler()
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await scheduler.advance(by: .seconds(1))
        await engine.perform { _ in }
        #expect(calls.value == [true])
        _ = await engine.perform { $0.start(owner: timerID, revision: 2) }
        await scheduler.advance(by: .milliseconds(500))
        await engine.perform { _ in }
        #expect(calls.value == [true])
        await scheduler.advance(by: .seconds(1))
        await engine.perform { _ in }
        #expect(calls.value == [true, false])
    }

    @Test
    func test_preempt_voiceOverOnly_doesNotActivateSession() async {
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(session: CueAudioSession(
            activate: { calls.withValue { $0.append(true) } },
            deactivate: { calls.withValue { $0.append(false) } }
        ), idleScheduler: DispatchQueue.test.eraseToAnyScheduler())
        #expect(await engine.perform { $0.preempt(owner: timerID, revision: 1) })
        #expect(calls.value.isEmpty)
        #expect(await engine.perform { $0.preempt(owner: timerID, revision: 1) } == false)
    }

    @Test
    func test_end_afterInterruption_deactivatesEvenWhenMirrorIsFalse() async {
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(session: CueAudioSession(
            activate: { calls.withValue { $0.append(true) } },
            deactivate: { calls.withValue { $0.append(false) } }
        ), idleScheduler: DispatchQueue.test.eraseToAnyScheduler())
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        await engine.perform { $0.handle(.interruptionBegan) }
        await engine.perform { $0.end(owner: timerID) }
        #expect(calls.value == [true, false])
    }

    @Test
    func test_start_inactiveScene_rejectsUntilActive() async {
        let engine = CueEngine(
            session: CueAudioSession(activate: {}, deactivate: {}),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler()
        )
        await engine.perform { $0.handle(.resignedActive) }
        #expect(await engine.perform { $0.start(owner: timerID, revision: 1) } == .rejected)
        await engine.perform { $0.handle(.becameActive) }
        #expect(await engine.perform { $0.start(owner: timerID, revision: 1) } == .admitted)
        await engine.perform { $0.end(owner: timerID) }
    }
}
