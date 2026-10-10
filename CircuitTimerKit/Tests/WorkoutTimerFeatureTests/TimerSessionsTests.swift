@testable import WorkoutTimerFeature

import ComposableArchitecture
import Foundation
import Testing

@MainActor
@Suite
struct TimerSessionsTests {
    private let first = UUID(fixture: 1)
    private let second = UUID(fixture: 2)
    private let applied = LockIsolated<[Bool]>([])

    private func makeSessions() -> TimerSessions {
        TimerSessions { [applied] isAwake in applied.withValue { $0.append(isAwake) } }
    }

    @Test
    func test_requestAwake_severalOwners_appliesWhetherAnyVotesAwake() {
        let sessions = makeSessions()

        sessions.requestAwake(owner: first, awake: true, revision: 1)
        sessions.requestAwake(owner: second, awake: false, revision: 1)
        sessions.requestAwake(owner: first, awake: false, revision: 2)
        sessions.requestAwake(owner: second, awake: true, revision: 2)
        sessions.end(owner: first)
        sessions.end(owner: second)

        #expect(applied.value == [true, true, false, true, true, false])
    }

    @Test(arguments: [(1, false), (2, false), (3, true)])
    func test_requestAwake_revisionAfterTheLastApplied_appliesOnlyWhenNewer(revision: Int, isApplied: Bool) {
        let sessions = makeSessions()
        sessions.requestAwake(owner: first, awake: true, revision: 2)

        sessions.requestAwake(owner: first, awake: false, revision: revision)

        #expect(applied.value == (isApplied ? [true, false] : [true]))
    }

    @Test
    func test_end_owner_rejectsItsLaterRequestsAndCanRepeat() {
        let sessions = makeSessions()
        sessions.requestAwake(owner: first, awake: true, revision: 1)

        sessions.end(owner: first)
        sessions.requestAwake(owner: first, awake: true, revision: 2)
        sessions.end(owner: first)

        #expect(applied.value == [true, false, false])
        #expect(sessions.isEnded(owner: first))
    }

    @Test
    func test_isEnded_unseenActiveAndUnknownEndedOwners_reportsOnlyEnded() {
        let sessions = makeSessions()
        let unknown = UUID(fixture: 3)

        #expect(!sessions.isEnded(owner: second))
        sessions.requestAwake(owner: second, awake: true, revision: 1)
        #expect(!sessions.isEnded(owner: second))
        sessions.end(owner: unknown)
        #expect(sessions.isEnded(owner: unknown))
        #expect(applied.value == [true, true])
    }

    @Test
    func test_openAndClose_threeScreensInARow_eachVoteStartsAndEnds() {
        let sessions = makeSessions()

        for number in 10..<13 {
            let owner = UUID(fixture: number)
            sessions.requestAwake(owner: owner, awake: true, revision: 1)
            sessions.end(owner: owner)
        }

        #expect(applied.value == [true, false, true, false, true, false])
    }
}
