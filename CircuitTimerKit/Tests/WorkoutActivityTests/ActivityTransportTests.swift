@testable import WorkoutActivity

import ActivityKit
import Testing

@Suite
struct ActivityTransportTests {
    @Test(arguments: [
        (ActivityAuthorizationError.denied, ActivityRequestFailure.denied),
        (.visibility, .visibility),
    ])
    func test_requestFailure_userAndForegroundRefusals_keepTheirMeaning(
        error: ActivityAuthorizationError,
        expected: ActivityRequestFailure
    ) {
        #expect(ActivityRequestFailure(error) == expected)
    }

    @Test(arguments: [ActivityAuthorizationError.attributesTooLarge, .unentitled, .unsupported, .unsupportedTarget])
    func test_requestFailure_retryCannotHelp_isPermanent(error: ActivityAuthorizationError) {
        guard case .permanent = ActivityRequestFailure(error) else {
            Issue.record("\(error) should be permanent")
            return
        }
    }

    @Test(arguments: [ActivityAuthorizationError.globalMaximumExceeded, .targetMaximumExceeded, .persistenceFailure])
    func test_requestFailure_otherRefusals_areTransient(error: ActivityAuthorizationError) {
        guard case .transient = ActivityRequestFailure(error) else {
            Issue.record("\(error) should be transient")
            return
        }
    }

    @Test
    func test_presence_endedOrDismissed_isGoneAndEverythingElseShows() {
        #expect(ActivityPresence(.ended) == .gone)
        #expect(ActivityPresence(.dismissed) == .gone)
        #expect(ActivityPresence(.active) == .alive)
        #expect(ActivityPresence(.stale) == .alive)
        if #available(iOS 26, *) {
            #expect(ActivityPresence(.pending) == .alive)
        }
    }
}
