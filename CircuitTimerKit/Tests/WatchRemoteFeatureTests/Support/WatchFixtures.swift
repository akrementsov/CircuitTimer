@testable import WatchRemoteFeature

import ComposableArchitecture
import Foundation
import SwiftUI
import WatchLink
import WorkoutDomain

let reachable = LinkStatus(isActivated: true, isReachable: true, needsUnlock: false)
let unreachable = LinkStatus(isActivated: true, isReachable: false, needsUnlock: false)
let earlier = Date(timeIntervalSince1970: 1_700_000_000)
let later = Date(timeIntervalSince1970: 1_700_000_600)

extension UUID {
    init(watch number: Int) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, UInt8(truncatingIfNeeded: number)))
    }
}

func watchCatalog(_ names: String...) -> WatchCatalog {
    WatchCatalog(entries: names.enumerated().map {
        WatchCatalog.Entry(
            id: UUID(watch: $0.offset + 1),
            name: $0.element,
            totalMilliseconds: 60_000,
            isPlayable: true,
            scheduleFingerprint: String(repeating: "0", count: 64)
        )
    })
}

func phoneState(
    process: Int = 1,
    sequence: Int,
    catalog: CatalogState? = nil,
    digest: String? = nil,
    at date: Date = earlier
) -> PhoneState {
    PhoneState(processID: UUID(watch: 100 + process), sequence: sequence, publishedAt: date, catalog: catalog, catalogDigest: digest)
}

func reply(_ requestID: UUID?, _ state: PhoneState) -> WatchReplyEnvelope {
    WatchReplyEnvelope(requestID: requestID, reply: .state(state))
}

/// The requests the reducer sent, in order.
final class SentRequests: Sendable {
    let requests = LockIsolated<[WatchRequest]>([])
    let answer = LockIsolated<@Sendable (UUID) throws -> WatchReplyEnvelope>({ _ in throw PhoneLinkError.unreachable })
}

@MainActor
func makeWatchStore(
    _ state: WatchRemoteFeature.State = WatchRemoteFeature.State(),
    sent: SentRequests = SentRequests(),
    clock: TestClock<Duration> = TestClock(),
    status: LinkStatus = reachable
) -> TestStoreOf<WatchRemoteFeature> {
    TestStore(initialState: state) {
        WatchRemoteFeature()
    } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.phoneCompanion.status = { status }
        $0.phoneCompanion.send = { requestID, request in
            sent.requests.withValue { $0.append(request) }
            return try sent.answer.value(requestID)
        }
    }
}

/// A state the reducer reaches when the iPhone's list arrived in a context; `inFront: false` for a watch app about to
/// come to the front.
func stateShowing(
    _ catalog: WatchCatalog,
    digest: String,
    process: Int = 1,
    sequence: Int = 1,
    inFront: Bool = true
) -> WatchRemoteFeature.State {
    var state = WatchRemoteFeature.State()
    state.link = reachable
    state.isSceneActive = inFront
    _ = state.order.receive(phoneState(process: process, sequence: sequence, catalog: .loaded(catalog), digest: digest), from: .context)
    state.catalog = .init(lastLoaded: catalog, updatedAt: earlier)
    return state
}

extension WatchRemoteFeature.RefreshRequest {
    /// The request the reducer records when it sends `id` as its `serial`-th request at the present of `clock`. Test
    /// clocks start at the same instant, so a fresh one stands for a store clock that has not moved.
    static func sent(_ id: UUID, serial: Int = 1, on clock: TestClock<Duration> = TestClock()) -> Self {
        Self(id: id, serial: serial, sentAt: MonotonicInstant(now: clock))
    }
}
