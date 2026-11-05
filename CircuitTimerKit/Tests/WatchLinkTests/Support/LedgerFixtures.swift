@testable import WatchLink

import Foundation

/// The revision of the access every ledger of the link's tests starts with; a later change takes a larger one.
let initialAccessRevision = 1

extension PublicationLedger {
    /// A ledger whose app already knows whether it has the full version: `.granted` as before the gate, unless a test
    /// of the gate starts it undecided (`nil`) or locked.
    static func make(
        processID: UUID = UUID(link: 1),
        link: FakeLink,
        access: WatchAccess? = .granted
    ) async -> PublicationLedger {
        let ledger = PublicationLedger(processID: processID, transport: link.transport)
        if let access {
            _ = await ledger.publishAccess(revision: initialAccessRevision, access: access, at: linkNow)
        }
        return ledger
    }

    /// Returns once every section enqueued before it ran: an `end` of an owner that never published changes nothing.
    func settle() async {
        _ = await end(owner: UUID(link: 255), at: linkNow)
    }
}

extension WatchCompanion {
    /// A companion on its own ledger, with the access the ledger starts with.
    static func make(
        processID: UUID = UUID(link: 1),
        link: FakeLink,
        access: WatchAccess? = .granted,
        now: @escaping @Sendable () -> Date = { linkNow },
        clock: any Clock<Duration>
    ) async -> WatchCompanion {
        WatchCompanion(
            ledger: await PublicationLedger.make(processID: processID, link: link, access: access),
            now: now,
            clock: clock
        )
    }
}
