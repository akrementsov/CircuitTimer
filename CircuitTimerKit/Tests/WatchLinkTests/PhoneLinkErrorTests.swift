@testable import WatchLink

import Foundation
import Testing
import WatchConnectivity

@Suite
struct PhoneLinkErrorTests {
    @Test(arguments: [
        (WCError.Code.notReachable, PhoneLinkError.unreachable),
        (.deliveryFailed, .unreachable),
        (.deviceNotPaired, .unreachable),
        (.watchAppNotInstalled, .unreachable),
        (.sessionNotActivated, .inactive),
        (.sessionInactive, .inactive),
        (.messageReplyTimedOut, .timedOut),
        (.transferTimedOut, .timedOut),
        (.companionAppNotInstalled, .companionMissing),
        (.payloadTooLarge, .payloadTooLarge),
        (.invalidParameter, .failed),
        (.payloadUnsupportedTypes, .failed),
        (.messageReplyFailed, .failed),
    ])
    func test_init_watchConnectivityCode_mapsToTheLinkState(code: WCError.Code, expected: PhoneLinkError) {
        #expect(PhoneLinkError(NSError(domain: WCErrorDomain, code: code.rawValue)) == expected)
    }

    @Test
    func test_init_sameCodeInAnotherDomain_isFailed() {
        #expect(PhoneLinkError(NSError(domain: NSCocoaErrorDomain, code: WCError.Code.notReachable.rawValue)) == .failed)
    }
}
