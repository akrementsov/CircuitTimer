@testable import WatchLink

import Foundation
import Testing
import TestSupport

/// The full version gate and the running workout: the run kept while the watch app is locked, a purchase that
/// publishes it again, a refund in a reply's way and a change of access around termination.
@Suite(.timeLimit(.minutes(1)))
struct PublicationLedgerAccessRunTests {
    private let link = FakeLink()

    private static let four: CatalogState = .loaded(makeCatalog(4))

    private func makeLedger(access: WatchAccess? = .granted) async -> PublicationLedger {
        await .make(link: link, access: access)
    }

    /// A purchase before the first list: the run goes out without a list, and without the lock's digest, which the
    /// watch would otherwise confirm and keep.
    @Test
    func test_publishAccess_grantedBeforeTheFirstList_publishesTheRunWithoutTheLocksDigest() async throws {
        let ledger = await makeLedger(access: .locked)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        let outcome = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)

        let state = try #require(try link.writtenStates().last)
        #expect(outcome == .written(state))
        #expect(state.catalog == nil)
        #expect(state.catalogDigest == nil)
        #expect(state.run == makeRun())
        #expect(state.isRunLive)
    }

    /// The owner ends while the watch app is locked: nothing is numbered or sent, and a purchase publishes no run.
    @Test
    func test_end_whileLocked_dropsTheKeptRun_withoutNumberingAnything() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        _ = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)
        let offered = link.offered.value.count

        // Without `markEnded`, so only `end` can be what keeps the run out of the purchase's state.
        let ended = await ledger.end(owner: owner(1), at: linkNow)

        #expect(ended == .skipped)
        #expect(link.offered.value.count == offered)
        #expect(link.messages.value.isEmpty)
        _ = await ledger.publishAccess(revision: 3, access: .granted, at: linkNow)
        let granted = try #require(try link.writtenStates().last)
        #expect(granted.catalog == Self.four)
        #expect(granted.run == nil)
    }

    /// The owner ends before StoreKit answered: nothing is numbered or sent, and the first decision publishes no run.
    @Test
    func test_end_beforeTheFirstDecision_dropsTheKeptRun_withoutNumberingAnything() async throws {
        let ledger = await makeLedger(access: nil)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        let offered = link.offered.value.count

        // Without `markEnded`, so only `end` can be what keeps the run out of the first decision's state.
        let ended = await ledger.end(owner: owner(1), at: linkNow)

        #expect(ended == .skipped)
        #expect(link.offered.value.count == offered)
        #expect(link.messages.value.isEmpty)
        _ = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)
        let granted = try #require(try link.writtenStates().last)
        #expect(granted.catalog == Self.four)
        #expect(granted.run == nil)
    }

    /// A run too large to travel stays hidden after a purchase while its owner is open, with the flag back; once its
    /// owner ended there is neither run nor flag.
    @Test(arguments: [false, true])
    func test_publishAccess_grantedAfterATooLargeRun_restoresTheFlagOnlyWhileItsOwnerIsOpen(ownerEnded: Bool) async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        _ = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)
        if ownerEnded {
            ledger.markEnded(owner(1))
            _ = await ledger.end(owner: owner(1), at: linkNow)
        }

        _ = await ledger.publishAccess(revision: 3, access: .granted, at: linkNow)

        let granted = try #require(try link.writtenStates().last)
        #expect(granted.catalog == Self.four)
        #expect(granted.run == nil)
        #expect(granted.isRunTooLarge == !ownerEnded)
    }

    /// A reply while the lock's write is held on the queue answers with the list and the run as they were, under
    /// the access they were published with; once the section adopts the lock, with the lock.
    @Test
    func test_reply_whileTheLockIsWritten_seesTheOldPairOrTheLock_neverAMix() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        let locking = Task { await ledger.publishAccess(revision: 2, access: .locked, at: linkNow) }
        await gate.started.wait { $0 }
        #expect(link.offeredStates().last?.catalog == .unavailable(.locked))

        let during = ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow)
        #expect(ledger.publishedAccess() == .granted)
        #expect(during.catalog == Self.four)
        #expect(during.run == makeRun())
        #expect(during.isRunLive)
        #expect(ledger.runOwner() == owner(1))

        gate.open()
        _ = await locking.value

        let after = ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow)
        #expect(ledger.publishedAccess() == .locked)
        #expect(after.catalog == .unavailable(.locked))
        #expect(after.run == nil)
        #expect(!after.isRunLive)
        #expect(ledger.runOwner() == nil)
    }

    /// A refund during termination, before or after the terminal write: the context ends with the lock, without a run.
    @Test(arguments: [false, true])
    func test_closeGate_thenLockAndTermination_inEitherOrder_endsWithTheLockWithoutARun(locksFirst: Bool) async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        let beforeGate = link.contexts.value.count
        ledger.closeGate()

        if locksFirst {
            _ = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)
            #expect(await ledger.finishTermination(at: linkNow) == .skipped)
        } else {
            _ = await ledger.finishTermination(at: linkNow)
            _ = await ledger.publishAccess(revision: 2, access: .locked, at: linkNow)
        }

        let written = try link.writtenStates()
        #expect(written.last?.catalog == .unavailable(.locked))
        #expect(written.last?.run == nil)
        #expect(written.dropFirst(beforeGate).allSatisfy { $0.run == nil })
    }

    /// A purchase after the gate closed writes the kept list, without the run: no owner is open any more.
    @Test
    func test_publishAccess_grantedAfterCloseGate_writesTheKeptListWithoutARun() async throws {
        let ledger = await makeLedger(access: .locked)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        ledger.closeGate()

        let outcome = await ledger.publishAccess(revision: 2, access: .granted, at: linkNow)

        let state = try #require(try link.writtenStates().last)
        #expect(outcome == .written(state))
        #expect(state.catalog == Self.four)
        #expect(state.run == nil)
        #expect(!state.isRunLive)
    }

    /// A purchase whose every candidate WatchConnectivity refused leaves the written lock for another access:
    /// termination writes what the purchase allows, without a run.
    @Test
    func test_finishTermination_afterAGrantRefusedForEveryCandidate_writesTheGrantedStateWithoutARun() async throws {
        let ledger = await makeLedger(access: .locked)
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
        #expect(await ledger.publishAccess(revision: 2, access: .granted, at: linkNow) == .skipped)
        #expect(ledger.publishedAccess() == .locked)
        #expect(try link.writtenStates().last?.catalog == .unavailable(.locked))
        ledger.closeGate()

        let outcome = await ledger.finishTermination(at: linkNow)

        let state = try #require(try link.writtenStates().last)
        #expect(outcome == .written(state))
        // The last candidate the refusals left, whichever it is: not the lock, and no run.
        #expect(state.catalog != .unavailable(.locked))
        #expect(state.run == nil)
        #expect(ledger.publishedAccess() == .granted)
    }
}
