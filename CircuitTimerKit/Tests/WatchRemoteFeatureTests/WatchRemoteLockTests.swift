@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import Testing
import WatchLink
import WorkoutDomain

/// The iPhone without the full version locks the watch app: the list goes, not dimmed, until the iPhone sends one again.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchRemoteLockTests {
    private static let catalog = watchCatalog("Morning")
    private static let lock = phoneState(sequence: 2, catalog: .unavailable(.locked), digest: "L", at: later)

    @Test
    func test_lock_dropsTheList_andALaterListBringsItBack() async {
        let store = makeWatchStore(stateShowing(Self.catalog, digest: "A"))

        await store.send(.internal(.event(.message(Self.lock)))) {
            _ = $0.order.receive(Self.lock, from: .message)
            $0.catalog = .init(lastLoaded: nil, unavailable: .locked, updatedAt: later)
        }
        #expect(store.state.screen == .locked(status: nil))

        let list = phoneState(sequence: 3, catalog: .loaded(Self.catalog), digest: "A", at: later)
        await store.send(.internal(.event(.message(list)))) {
            _ = $0.order.receive(list, from: .message)
            $0.catalog = .init(lastLoaded: Self.catalog, updatedAt: later)
        }
        #expect(store.state.screen == .list(Self.catalog, dimmed: nil, status: nil))
        await store.finish()
    }

    enum Shown: CaseIterable, Sendable {
        case nothing
        case selection
        case pendingStart
        case startNote
    }

    /// The lock takes the user back to the root and stops a Start on its way without a note: the lock says why.
    @Test(arguments: Shown.allCases)
    func test_lock_clearsTheSelectionAndStopsAStartWithoutANote(shown: Shown) async {
        let clock = TestClock<Duration>()
        let entry = Self.catalog.entries[0]
        var state = stateShowing(Self.catalog, digest: "A")
        if shown != .nothing {
            state.path.append(.selected(id: entry.id, fingerprint: entry.scheduleFingerprint))
        }
        switch shown {
            case .nothing, .selection:
                break
            case .pendingStart:
                state.start = .init(id: UUID(watch: 50), beganAt: MonotonicInstant(now: clock))
            case .startNote:
                state.startNote = .checkPhone
        }
        let store = makeWatchStore(state, clock: clock)

        await store.send(.internal(.event(.message(Self.lock)))) {
            _ = $0.order.receive(Self.lock, from: .message)
            $0.catalog = .init(lastLoaded: nil, unavailable: .locked, updatedAt: later)
            $0.path.removeAll()
            $0.start = nil
            $0.startNote = nil
        }

        #expect(store.state.startStatus == nil)
        await store.finish()
    }
}
