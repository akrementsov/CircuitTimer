@testable import WatchLink

import Foundation
import Testing

/// The full version gate in the ledger: what it numbers, writes and sends while the app does not know the status, after
/// a refund and after a purchase, and how a refused write of the lock is retried.
@Suite(.timeLimit(.minutes(1)))
struct PublicationLedgerAccessTests {
    private let link = FakeLink()

    private static let four: CatalogState = .loaded(makeCatalog(4))

    private func makeLedger(access: WatchAccess? = .granted) async -> PublicationLedger {
        await .make(link: link, access: access)
    }

    /// Locked from an undecided app with a list kept and from one that published a list and a hidden run: the lock
    /// carries neither, is numbered above everything offered before, and replies answer with it.
    @Test(arguments: [nil, WatchAccess.granted] as [WatchAccess?])
    func test_publishAccess_locked_numbersTheLockAboveEveryEarlierState(from access: WatchAccess?) async throws {
        let ledger = await makeLedger(access: access)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        if access == .granted {
            link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
            _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
            #expect(try link.writtenStates().last?.isRunTooLarge == true)
        }
        let earlier = link.offeredStates().map(\.sequence).max() ?? 0

        let outcome = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)

        let lock = try #require(try link.writtenStates().last)
        #expect(outcome == .written(lock))
        #expect(lock.catalog == .unavailable(.locked))
        #expect(lock.catalogDigest == (try lockedDigest()))
        #expect(lock.catalogDigest != (try WatchCatalog.digest(of: Self.four)))
        #expect(lock.catalogDigest != (try WatchCatalog.digest(of: .loaded(WatchCatalog(entries: [])))))
        #expect(lock.run == nil)
        #expect(!lock.isRunLive)
        #expect(!lock.isRunTooLarge)
        #expect(lock.sequence == earlier + 1)
        #expect(ledger.publishedAccess() == .locked)
        let reply = ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow)
        #expect(reply.catalog == .unavailable(.locked))
        #expect(reply.run == nil)
        #expect(!reply.isRunLive)
        #expect(ledger.runOwner() == nil)
    }

    @Test
    func test_publishAccess_firstGrantWithNothingPublished_numbersNothing_andRepliesWithoutACatalog() async throws {
        let ledger = await makeLedger(access: nil)

        let outcome = await ledger.publishAccess(revision: 1, access: .granted, at: linkNow)

        #expect(outcome == .skipped)
        #expect(link.offered.value.isEmpty)
        #expect(ledger.publishedAccess() == .granted)
        let reply = ledger.reply(knownCatalogDigest: nil, answeredBy: nil, at: linkNow)
        #expect(reply.sequence == 0)
        #expect(reply.catalog == nil)
        #expect(reply.catalogDigest == nil)
        // The first publication numbers the first state.
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        #expect(try link.writtenStates().map(\.sequence) == [1])
    }

    /// The same access again is no change: nothing is numbered, and a state numbered before it is still sent.
    @Test
    func test_publishAccess_sameAccessNewerRevision_skips_andKeepsSendingStatesNumberedBefore() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        let state = try #require(try link.writtenStates().last)

        let again = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)
        await ledger.send(state)

        #expect(again == .skipped)
        #expect(link.offered.value.count == 1)
        #expect(try link.sentStates() == [state])
        // An older revision is ignored, whatever access it carries.
        #expect(await ledger.publishAccess(revision: 2, access: .locked, at: linkNow) == .skipped)
        #expect(ledger.publishedAccess() == .granted)
        #expect(link.offered.value.count == 1)
    }

    /// A refund's revision 5 and a purchase's revision 6 handled in reverse order: the purchase stands.
    @Test
    func test_publishAccess_olderLockAfterANewerGrant_isIgnored() async throws {
        let ledger = await makeLedger(access: nil)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)

        let granted = await ledger.publishAccess(revision: 6, access: .granted, at: linkNow)
        let locked = await ledger.publishAccess(revision: 5, access: .locked, at: linkNow)

        let state = try #require(try link.writtenStates().last)
        #expect(granted == .written(state))
        #expect(locked == .skipped)
        #expect(try link.writtenStates().catalogs == [Self.four])
        #expect(ledger.publishedAccess() == .granted)
    }

    /// Without access the catalog and the run are kept, not numbered, written or sent; a purchase publishes them.
    @Test(arguments: [nil, WatchAccess.locked] as [WatchAccess?])
    func test_publish_withoutAccess_keepsTheCatalogAndTheRunUnpublished(access: WatchAccess?) async throws {
        let ledger = await makeLedger(access: access)
        let offeredBefore = link.offered.value.count

        #expect(await ledger.publish(revision: 1, catalog: Self.four, at: linkNow) == .skipped)
        #expect(await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow) == .skipped)
        ledger.writeLatestAndSend()
        await ledger.settle()

        #expect(link.offered.value.count == offeredBefore)
        #expect(link.messages.value.isEmpty)
        #expect(ledger.publishedAccess() == access)
        _ = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)
        let granted = try #require(try link.writtenStates().last)
        #expect(granted.catalog == Self.four)
        #expect(granted.run == makeRun())
    }

    @Test
    func test_publishAccess_grantedAfterTheLock_publishesTheKeptCatalogAndRun_newestOnlyAndOnce() async throws {
        let ledger = await makeLedger(access: .locked)
        let lock = try #require(try link.writtenStates().last)
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(2)), at: linkNow)
        _ = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(3)), at: linkNow)
        _ = await ledger.publishRun(revision: 5, run: makeRun(), at: linkNow)
        #expect(link.offeredStates() == [lock])

        let outcome = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)

        let offered = Array(link.offeredStates().dropFirst())
        #expect(offered.count == 1)
        let granted = try #require(offered.first)
        #expect(outcome == .written(granted))
        #expect(granted.catalog == .loaded(makeCatalog(3)))
        #expect(granted.run == makeRun())
        #expect(granted.isRunLive)
        #expect(granted.sequence > lock.sequence)
        // The run kept its revision: the timer's answer on it is live.
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 5), at: linkNow).isRunLive)
        #expect(!ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 6), at: linkNow).isRunLive)
    }

    @Test
    func test_publishAccess_lockRefusedAsTooLarge_isPending_andRepliesAnswerWithIt() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        let written = try link.writtenStates()
        link.refusals.setValue([FakeLink.tooLarge])

        let outcome = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)

        guard case let .pending(lock) = outcome else {
            Issue.record("A refused lock was not pending: \(outcome)")
            return
        }
        #expect(lock.catalog == .unavailable(.locked))
        #expect(lock.sequence == 3)
        #expect(try link.writtenStates() == written)
        #expect(ledger.publishedAccess() == .locked)
        let reply = ledger.reply(knownCatalogDigest: "list", answeredBy: (owner(1), 1), at: linkNow)
        #expect(reply.catalog == .unavailable(.locked))
        #expect(reply.sequence == 3)
        #expect(reply.run == nil)
        #expect(!reply.isRunLive)
        let confirmation = ledger.reply(knownCatalogDigest: try lockedDigest(), answeredBy: nil, at: linkNow)
        #expect(confirmation.catalog == nil)
        #expect(confirmation.catalogDigest == (try lockedDigest()))
    }

    enum Retry: CaseIterable, Sendable {
        case written
        case refusedAgain
        case cannotPublish
    }

    /// The lock refused as too large is written again at the next activation: as it is once it fits, numbered anew
    /// while it is refused again, not at all while the link cannot publish.
    @Test(arguments: Retry.allCases)
    func test_writeLatestAndSend_afterARefusedLock_retriesTheLock(retry: Retry) async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge])
        guard case let .pending(lock) = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow) else {
            Issue.record("The refused lock was not pending")
            return
        }
        let written = try link.writtenStates()

        switch retry {
            case .written:
                ledger.writeLatestAndSend()
                await ledger.settle()
                #expect(try link.writtenStates() == written + [lock])
                #expect(link.messages.value.isEmpty)
                #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: nil, at: linkNow).sequence == lock.sequence)
                let offered = link.offered.value.count
                ledger.writeLatestAndSend()
                await ledger.settle()
                #expect(link.offered.value.count == offered)
                #expect(link.messages.value.isEmpty)
            case .refusedAgain:
                for attempt in 1...2 {
                    // The lock itself, then the lock numbered anew in its place.
                    link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge])
                    ledger.writeLatestAndSend()
                    await ledger.settle()
                    let sent = try link.sentStates()
                    #expect(sent.count == attempt)
                    #expect(sent.last?.sequence == lock.sequence + attempt)
                    #expect(sent.last?.catalog == .unavailable(.locked))
                    #expect(try link.writtenStates() == written)
                    let reply = ledger.reply(knownCatalogDigest: nil, answeredBy: nil, at: linkNow)
                    #expect(reply.catalog == .unavailable(.locked))
                    #expect(reply.sequence == lock.sequence + attempt)
                }
            case .cannotPublish:
                link.snapshot.withValue { $0.canPublish = false }
                let offered = link.offered.value.count
                ledger.writeLatestAndSend()
                await ledger.settle()
                #expect(link.offered.value.count == offered)
                #expect(link.messages.value.isEmpty)
                #expect(try link.writtenStates() == written)
                // Still unwritten: the next activation that can publish writes it.
                link.snapshot.withValue { $0.canPublish = true }
                ledger.writeLatestAndSend()
                await ledger.settle()
                #expect(try link.writtenStates() == written + [lock])
        }
    }

    /// A state built for the access before the change is never written again: the activation numbers the state the
    /// current access allows.
    @Test
    func test_writeLatestAndSend_afterAChangeOfAccess_rebuildsForTheCurrentAccess() async throws {
        let ledger = await makeLedger(access: nil)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.snapshot.withValue { $0.canPublish = false }
        guard case let .pending(lock) = await ledger.publishAccess(revision: 1, access: .locked, at: linkNow) else {
            Issue.record("The lock that could not be written was not pending")
            return
        }
        link.snapshot.withValue { $0.canPublish = true }
        // Every candidate of the purchase is refused: the section numbers them but adopts none.
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
        #expect(await ledger.publishAccess(revision: 2, access: .granted, at: linkNow) == .skipped)
        #expect(ledger.publishedAccess() == .locked)

        ledger.writeLatestAndSend()
        await ledger.settle()

        let written = try link.writtenStates()
        #expect(written.count == 1)
        #expect(!written.contains(lock))
        #expect(written.last?.catalog == .unavailable(.tooLarge))
        #expect(written.last.map { $0.sequence > lock.sequence } == true)
        #expect(try link.sentStates() == written)
        #expect(ledger.publishedAccess() == .granted)
    }

    /// A state numbered before the change is sent only before the access section; the lock and later states go out.
    @Test
    func test_send_stateNumberedBeforeTheChange_isSentOnlyBeforeIt() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        let list = try #require(try link.writtenStates().last)
        await ledger.send(list)

        guard case let .written(lock) = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow) else {
            Issue.record("The lock was not written")
            return
        }
        await ledger.send(list)
        await ledger.send(lock)
        guard case let .written(granted) = await ledger.publishAccess(revision: 3, access: .granted, at: linkNow) else {
            Issue.record("The purchase's state was not written")
            return
        }
        await ledger.send(lock)
        await ledger.send(granted)

        #expect(try link.sentStates() == [list, lock, granted])
    }
}
