@testable import WatchRemoteFeature

import Foundation
import Testing
import WatchLink
import WorkoutDomain

@Suite
struct WatchRemoteFeatureScreenTests {
    private static let list = watchCatalog("Morning", "Evening")

    private static func state(
        link: LinkStatus? = reachable,
        catalog: WatchRemoteFeature.ShownCatalog? = nil,
        problem: WatchRemoteFeature.LinkProblem? = nil,
        hasAnswered: Bool = true,
        inFlight: Bool = false
    ) -> WatchRemoteFeature.State {
        var state = WatchRemoteFeature.State()
        state.link = link
        state.catalog = catalog
        state.problem = problem
        state.refresh.hasAnswered = hasAnswered
        state.refresh.inFlight = inFlight
            ? WatchRemoteFeature.RefreshRequest(id: UUID(watch: 1), serial: 1, sentAt: MonotonicInstant(now: ContinuousClock()))
            : nil
        return state
    }

    private static let activating = LinkStatus(isActivated: false, isReachable: false, needsUnlock: false, isActivating: true)
    private static let failedActivation = LinkStatus(isActivated: false, isReachable: false, needsUnlock: false)
    private static let locked = LinkStatus(isActivated: true, isReachable: false, needsUnlock: true)

    @Test(arguments: [
        (state(problem: .incompatible(.phone), hasAnswered: true), WatchRemoteFeature.State.Screen.update(.phone)),
        (state(catalog: .init(lastLoaded: list, updatedAt: earlier), problem: .incompatible(.watch)), .update(.watch)),
        (state(catalog: .init(lastLoaded: list, updatedAt: earlier)), .list(list, dimmed: nil, status: nil)),
        (
            state(catalog: .init(lastLoaded: list, unavailable: .loadFailed, updatedAt: earlier)),
            .list(list, dimmed: .loadFailed, status: nil)
        ),
        (state(catalog: .init(lastLoaded: watchCatalog(), updatedAt: earlier)), .empty(status: nil)),
        (state(catalog: .init(unavailable: .loadFailed, updatedAt: earlier)), .unavailable(.loadFailed, status: nil)),
        (state(catalog: .init(unavailable: .tooLarge, updatedAt: earlier)), .unavailable(.tooLarge, status: nil)),
        (state(link: locked, problem: .companionMissing), .notice(.unlock)),
        (state(problem: .companionMissing), .notice(.companionMissing)),
        (state(link: nil, hasAnswered: false), .notice(.connecting)),
        (state(link: activating, hasAnswered: false), .notice(.connecting)),
        (state(hasAnswered: false, inFlight: true), .notice(.connecting)),
        (state(link: failedActivation, hasAnswered: false), .notice(.unreachable)),
        (state(link: unreachable), .notice(.unreachable)),
        (state(problem: .failed), .notice(.unreachable)),
        (state(), .notice(.noCatalog)),
    ])
    func test_screen_state_followsThePriorityOfTheTable(state: WatchRemoteFeature.State, expected: WatchRemoteFeature.State.Screen) {
        #expect(state.screen == expected)
    }

    @Test(arguments: [
        (
            state(link: locked, catalog: .init(lastLoaded: list, updatedAt: earlier), problem: .failed),
            WatchRemoteFeature.State.StatusLine.unlock
        ),
        (state(catalog: .init(lastLoaded: list, updatedAt: earlier), problem: .companionMissing), .companionMissing),
        (state(catalog: .init(lastLoaded: list, updatedAt: earlier), problem: .unreachable), .unreachable(updatedAt: earlier)),
        (state(catalog: .init(lastLoaded: list, updatedAt: earlier), problem: .failed), .failed(updatedAt: earlier)),
        (state(link: unreachable, catalog: .init(lastLoaded: list, updatedAt: earlier)), .unreachable(updatedAt: earlier)),
    ])
    func test_statusLine_listWithAProblem_saysWhyItMayBeOld(
        state: WatchRemoteFeature.State,
        expected: WatchRemoteFeature.State.StatusLine
    ) {
        #expect(state.screen == .list(Self.list, dimmed: nil, status: expected))
    }

    @Test
    func test_statusLine_activatingSession_isNotUnreachable() {
        let state = Self.state(link: Self.activating, catalog: .init(lastLoaded: Self.list, updatedAt: earlier))

        #expect(state.screen == .list(Self.list, dimmed: nil, status: nil))
    }

    @Test(arguments: [(" ", true), (" \n\t", true), ("", true), ("a ", false), ("Tabata", false)])
    func test_isUntitled_name_matchesTheIPhonesRule(name: String, expected: Bool) {
        let entry = WatchCatalog.Entry(
            id: UUID(watch: 1),
            name: name,
            totalMilliseconds: 1,
            isPlayable: true,
            scheduleFingerprint: String(repeating: "0", count: 64)
        )

        #expect(entry.isUntitled == expected)
    }
}
