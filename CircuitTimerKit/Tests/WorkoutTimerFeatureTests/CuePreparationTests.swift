@testable import WorkoutTimerFeature

import AVFAudio
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct CuePreparationTests {
    @Test
    func test_prepare_countdown_consumesThePreparedPlayerWithoutLoadingAtTheCue() async {
        let created = LockIsolated(0)
        let calls = LockIsolated<[String]>([])
        let player = PreparedPlayer(calls: calls)
        let engine = CueEngine(
            session: CueAudioSession(activate: {}, deactivate: {}),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler(),
            makePlayer: { _ in
                created.withValue { $0 += 1 }
                return player
            }
        )
        #expect(await engine.perform { $0.prepare(owner: timerID, revision: 1) }.failures.isEmpty)
        #expect(created.value == 1)
        #expect(calls.value == ["prepare"])
        #expect(await engine.perform { $0.start(owner: timerID, revision: 2) } == .admitted)
        _ = await engine.perform { $0.startTone(.countdown, owner: timerID, revision: 2) }
        #expect(created.value == 1)
        #expect(calls.value == ["prepare", "play"])
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_prepare_newerReservation_staleSuspendDoesNotDiscardIt() async {
        let created = LockIsolated(0)
        let sessions = LockIsolated<[Bool]>([])
        let player = PreparedPlayer(calls: LockIsolated([]))
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { sessions.withValue { $0.append(true) } },
                deactivate: { sessions.withValue { $0.append(false) } }
            ),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler(),
            makePlayer: { _ in
                created.withValue { $0 += 1 }
                return player
            }
        )
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 1) }
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 2) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(sessions.value == [true])
        _ = await engine.perform { $0.start(owner: timerID, revision: 3) }
        _ = await engine.perform { $0.startTone(.countdown, owner: timerID, revision: 3) }
        #expect(created.value == 1)
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_prepare_newReservation_stopsThePreviousOutputBeforeStaleSuspension() async {
        let calls = LockIsolated<[String]>([])
        let oldPlayer = PreparedPlayer(calls: calls)
        let newPlayer = PreparedPlayer(calls: LockIsolated([]))
        let created = LockIsolated(0)
        let engine = CueEngine(
            session: CueAudioSession(activate: {}, deactivate: {}),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler(),
            makePlayer: { _ in
                let index = created.withValue { count in
                    defer { count += 1 }
                    return count
                }
                return index == 0 ? oldPlayer : newPlayer
            }
        )
        _ = await engine.perform { $0.start(owner: timerID, revision: 1) }
        _ = await engine.perform { $0.startTone(.countdown, owner: timerID, revision: 1) }
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 2) }
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        #expect(calls.value == ["prepare", "play", "stop"])
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_prepare_categoryChangeNotification_doesNotDiscardThePreparedPlayer() async {
        let created = LockIsolated(0)
        let player = PreparedPlayer(calls: LockIsolated([]))
        let engine = CueEngine(
            session: CueAudioSession(activate: {}, deactivate: {}),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler(),
            makePlayer: { _ in
                created.withValue { $0 += 1 }
                return player
            }
        )
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 1) }
        let reason = Int(AVAudioSession.RouteChangeReason.categoryChange.rawValue)
        await engine.perform { $0.handle(.routeChanged(reason)) }
        _ = await engine.perform { $0.start(owner: timerID, revision: 2) }
        _ = await engine.perform { $0.startTone(.countdown, owner: timerID, revision: 2) }
        #expect(created.value == 1)
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_prepare_suspendedBeforeAdmission_doesNotActivateOrLoad() async {
        let calls = LockIsolated<[Bool]>([])
        let engine = CueEngine(session: CueAudioSession(
            activate: { calls.withValue { $0.append(true) } },
            deactivate: { calls.withValue { $0.append(false) } }
        ), idleScheduler: DispatchQueue.test.eraseToAnyScheduler())
        await engine.perform { $0.suspend(owner: timerID, through: 1) }
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 1) }
        #expect(calls.value.isEmpty)
    }

    @Test
    func test_prepare_playerCannotPrepare_reportsFailureAndReleasesSession() async {
        let sessions = LockIsolated<[Bool]>([])
        let player = PreparedPlayer(calls: LockIsolated([]), canPrepare: false)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { sessions.withValue { $0.append(true) } },
                deactivate: { sessions.withValue { $0.append(false) } }
            ),
            idleScheduler: DispatchQueue.test.eraseToAnyScheduler(),
            makePlayer: { _ in player }
        )
        let result = await engine.perform { $0.prepare(owner: timerID, revision: 1) }
        #expect(result.failures == [.playerFailed])
        #expect(sessions.value == [true, false])
        await engine.perform { $0.end(owner: timerID) }
    }

    @Test
    func test_prepare_idleDeadline_stopsUnusedPlayerAndReleasesDucking() async {
        let scheduler = DispatchQueue.test
        let sessions = LockIsolated<[Bool]>([])
        let calls = LockIsolated<[String]>([])
        let player = PreparedPlayer(calls: calls)
        let engine = CueEngine(
            session: CueAudioSession(
                activate: { sessions.withValue { $0.append(true) } },
                deactivate: { sessions.withValue { $0.append(false) } }
            ),
            idleScheduler: scheduler.eraseToAnyScheduler(),
            makePlayer: { _ in player }
        )
        _ = await engine.perform { $0.prepare(owner: timerID, revision: 1) }
        await scheduler.advance(by: .milliseconds(1_500))
        await engine.perform { _ in }
        #expect(sessions.value == [true, false])
        #expect(calls.value == ["prepare", "stop"])
    }
}

private final class PreparedPlayer: CuePlayer, @unchecked Sendable {
    var delegate: (any AVAudioPlayerDelegate)?
    let calls: LockIsolated<[String]>
    let canPrepare: Bool

    init(calls: LockIsolated<[String]>, canPrepare: Bool = true) {
        self.calls = calls
        self.canPrepare = canPrepare
    }

    func prepareToPlay() -> Bool {
        calls.withValue { $0.append("prepare") }
        return canPrepare
    }

    func play() -> Bool {
        calls.withValue { $0.append("play") }
        return true
    }

    func stop() {
        calls.withValue { $0.append("stop") }
    }
}
