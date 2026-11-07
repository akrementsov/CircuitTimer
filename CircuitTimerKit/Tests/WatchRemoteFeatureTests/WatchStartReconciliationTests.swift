@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchStartReconciliationTests {
    enum Invalid: CaseIterable, Sendable { case unavailable, gone, changed, notPlayable }

    @Test(arguments: Invalid.allCases, [false, true])
    func test_catalog_invalidatesSelection_preservesPendingOrShowsOutcome(variant: Invalid, pending: Bool) async {
        let clock = TestClock<Duration>()
        let catalog = watchCatalog("Morning")
        let entry = catalog.entries[0]
        var state = stateShowing(catalog, digest: "A")
        state.link = unreachable
        state.path.append(.selected(id: entry.id, fingerprint: entry.scheduleFingerprint))
        if pending { state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock)) }
        let update: CatalogState
        let note: WatchRemoteFeature.StartNote
        switch variant {
            case .unavailable:
                update = .unavailable(.loadFailed)
                note = .listUnavailable
            case .gone:
                update = .loaded(WatchCatalog(entries: []))
                note = .gone
            case .changed, .notPlayable:
                update = .loaded(WatchCatalog(entries: [
                    WatchCatalog.Entry(
                        id: entry.id,
                        name: entry.name,
                        totalMilliseconds: 0,
                        isPlayable: false,
                        scheduleFingerprint: variant == .changed ? "changed" : entry.scheduleFingerprint
                    ),
                ]))
                note = variant == .changed ? .changed : .notPlayable
        }
        let store = makeWatchStore(state, clock: clock)
        let published = phoneState(sequence: 2, catalog: update, digest: "B")
        await store.send(.internal(.event(.message(published)))) {
            _ = $0.order.receive(published, from: .message)
            switch update {
                case let .loaded(loaded): $0.catalog = .init(lastLoaded: loaded, updatedAt: earlier)
                case let .unavailable(reason): $0.catalog?.unavailable = reason
            }
            $0.path.removeAll()
            if !pending { $0.startNote = note }
        }
        #expect(store.state.startStatus == (pending ? .sending : note))
        if pending {
            await store.send(.view(.scenePhaseChanged(.background))) {
                $0.isSceneActive = false
                $0.start = nil
            }
        }
        await store.finish()
    }

    @Test(arguments: [false, true])
    func test_workoutTapped_dimmedOrUnplayableRow_returnsToRootWithReason(dimmed: Bool) async {
        let entry = WatchCatalog.Entry(
            id: UUID(watch: 1), name: "Morning", totalMilliseconds: 0, isPlayable: dimmed, scheduleFingerprint: "fp"
        )
        var state = stateShowing(WatchCatalog(entries: [entry]), digest: "A")
        if dimmed { state.catalog?.unavailable = .loadFailed }
        let store = makeWatchStore(state)
        await store.send(.view(.workoutTapped(entry.id))) {
            $0.startNote = dimmed ? .listUnavailable : .notPlayable
        }
        #expect(store.state.path.isEmpty)
        await store.finish()
    }

    @Test(arguments: [false, true], [false, true])
    func test_run_inRefusalOrPublication_clearsSelectionPendingAndOldOutcome(tooLarge: Bool, inReply: Bool) async {
        let clock = TestClock<Duration>()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.link = unreachable
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        if inReply {
            state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
        } else {
            state.startNote = .checkPhone
        }
        let store = makeWatchStore(state, clock: clock)
        let run = heldRun(.paused(heldStage))
        let published = runState(sequence: 2, run: tooLarge ? nil : run, tooLarge: tooLarge)
        let action: WatchRemoteFeature.Action = inReply
            ? .internal(.startAnswered(
                sentID: UUID(watch: 50), WatchReplyEnvelope(requestID: UUID(watch: 50), reply: .start(.busy, published))
            ))
            : .internal(.event(.message(published)))
        await store.send(action) {
            _ = $0.order.receive(published, from: inReply ? .reply : .message)
            $0.isRunTooLarge = tooLarge
            if !tooLarge {
                $0.run = .init(run: run, isLive: true)
                $0.runGeneration = 1
            }
            $0.start = nil
            $0.startNote = nil
            $0.path.removeAll()
        }
        #expect(store.state.lease == nil)
        await store.finish()
    }

    @Test
    func test_unknownDigest_confirmationEnablesSameSelectionWithoutClosingIt() async {
        let clock = TestClock<Duration>()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        state.link = unreachable
        _ = state.order.receive(phoneState(sequence: 2, digest: "B"), from: .message)
        let store = makeWatchStore(state, clock: clock)
        let confirmation = phoneState(sequence: 3, digest: "A")
        await store.send(.internal(.event(.message(confirmation)))) {
            _ = $0.order.receive(confirmation, from: .message)
        }
        #expect(store.state.selection == .ready(catalog.entries[0]))
        #expect(store.state.path.count == 1)
        await store.finish()
    }

    @Test
    func test_start_realSendTimeout_releasesUUIDAndNextStartUsesNewOne() async {
        let clock = TestClock<Duration>()
        let held = HeldReplies()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        let store = makeWatchStore(state, clock: clock) { $0.phoneCompanion.send = { id, _ in try await held.send(id) } }
        await store.send(.view(.startButtonTapped)) {
            $0.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        }
        await clock.advance(by: .seconds(10))
        await store.receive(.internal(.startTimedOut(sentID: UUID(0), generation: 0))) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.send(.view(.startButtonTapped)) {
            $0.startNote = nil
            $0.start = .init(id: UUID(1), beganAt: MonotonicInstant(now: clock))
        }
        await held.waiting.wait { $0 == [UUID(1)] }
        await store.send(.internal(.startTimedOut(sentID: UUID(0), generation: 0)))
        await store.send(.internal(.startFailed(sentID: UUID(0), .failed)))
        let old = WatchReplyEnvelope(requestID: UUID(0), reply: .start(.busy, phoneState(sequence: 2)))
        await store.send(.internal(.startAnswered(sentID: UUID(0), old)))
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }

    @Test
    func test_accepted_delayedReply_startsThirtyFiveSecondsAtReceipt() async {
        let clock = TestClock<Duration>()
        let held = HeldReplies()
        let catalog = watchCatalog("Morning")
        var state = stateShowing(catalog, digest: "A")
        state.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        // The wait's polls are answered at once without a run; only the Start's reply is held.
        let store = makeWatchStore(state, clock: clock) {
            $0.phoneCompanion.send = { id, request in
                if case .refresh = request { return reply(id, phoneState(sequence: 1, digest: "A")) }
                return try await held.send(id)
            }
        }
        await store.send(.view(.startButtonTapped)) {
            $0.start = .init(id: UUID(0), beganAt: MonotonicInstant(now: clock))
        }
        await clock.advance(by: .seconds(9))
        await held.answer {
            WatchReplyEnvelope(requestID: $0, reply: .start(.accepted(asksOnPhone: false), phoneState(sequence: 1, digest: "A")))
        }
        await store.receive(\.internal.startAnswered) {
            $0.start?.beganAt = MonotonicInstant(now: clock)
            $0.start?.stage = .waiting(asksOnPhone: false)
            $0.start?.timeoutGeneration = 1
        }
        // The polls in between are `WatchStartPollTests`' subject; this test guards when the wait ends.
        store.exhaustivity = .off(showSkippedAssertions: false)
        await clock.advance(by: .seconds(34))
        #expect(store.state.startStatus == .starting)
        await clock.advance(by: .seconds(1))
        await store.receive(.internal(.startTimedOut(sentID: UUID(0), generation: 1))) {
            $0.start = nil
            $0.startNote = .checkPhone
        }
        await store.finish()
    }

    @Test(arguments: [0, 1, 2, 3])
    func test_pending_linkLost_statusSurvivesEveryRootScreen(kind: Int) async {
        let clock = TestClock<Duration>()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.refresh.hasAnswered = true
        switch kind {
            case 1: state.catalog?.lastLoaded = WatchCatalog(entries: [])
            case 2: state.catalog = .init(unavailable: .loadFailed, updatedAt: earlier)
            case 3: state.catalog = nil
            default: break
        }
        state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, clock: clock)
        await store.send(.internal(.event(.status(unreachable)))) { $0.link = unreachable }
        #expect(store.state.startStatus == .sending)
        switch kind {
            case 1: #expect(store.state.screen == .empty(status: .unreachable(updatedAt: earlier)))
            case 2: #expect(store.state.screen == .unavailable(.loadFailed, status: .unreachable(updatedAt: earlier)))
            case 3: #expect(store.state.screen == .notice(.unreachable))
            default:
                #expect(store.state.screen == .list(watchCatalog("Morning"), dimmed: nil, status: .unreachable(updatedAt: earlier)))
        }
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.start = nil
        }
        await store.finish()
    }

    @Test
    func test_foreignStartReply_refreshesOnceWithoutChangingFollowedProcessOrLease() async {
        let clock = TestClock<Duration>()
        let held = HeldReplies()
        let sent = SentRequests()
        var state = stateShowing(watchCatalog("Morning"), digest: "A")
        state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
        let store = makeWatchStore(state, sent: sent, clock: clock) {
            $0.phoneCompanion.send = { id, request in
                sent.requests.withValue { $0.append(request) }
                return try await held.send(id)
            }
        }
        let foreign = phoneState(process: 2, sequence: 0)
        let envelope = WatchReplyEnvelope(requestID: UUID(watch: 50), reply: .start(.accepted(asksOnPhone: false), foreign))
        await store.send(.internal(.startAnswered(sentID: UUID(watch: 50), envelope))) {
            _ = $0.order.receive(foreign, from: .message)
            $0.refresh.lastSerial = 1
            $0.refresh.inFlight = .sent(UUID(0), on: clock)
            $0.refresh.retryGeneration = 1
            $0.refresh.runRetryGeneration = 1
            $0.start?.stage = .waiting(asksOnPhone: false)
            $0.start?.timeoutGeneration = 1
        }
        await held.waiting.wait { !$0.isEmpty }
        await store.send(.internal(.event(.message(foreign))))
        #expect(store.state.order.processID == UUID(watch: 101))
        #expect(store.state.lease == nil)
        #expect(sent.requests.value == [.refresh(knownCatalogDigest: "A")])
        await store.send(.view(.scenePhaseChanged(.background))) {
            $0.isSceneActive = false
            $0.refresh.inFlight = nil
            $0.start = nil
        }
        await store.finish()
    }

    @Test
    func test_workoutTapped_existingSelection_replacesPathWithOnlyNewWorkout() async {
        let catalog = watchCatalog("Morning", "Evening")
        let store = makeWatchStore(stateShowing(catalog, digest: "A"))
        await store.send(.view(.workoutTapped(UUID(watch: 1)))) {
            $0.path.append(.selected(id: UUID(watch: 1), fingerprint: catalog.entries[0].scheduleFingerprint))
        }
        await store.send(.view(.workoutTapped(UUID(watch: 2)))) {
            $0.path.removeAll()
            $0.path.append(.selected(id: UUID(watch: 2), fingerprint: catalog.entries[1].scheduleFingerprint))
        }
        #expect(store.state.path.count == 1)
        await store.finish()
    }

}
