@testable import WatchLink

import Dependencies
import Foundation
import Testing
import TestSupport

/// The running workout in the published state: numbering, liveness, the room it takes, and how its owner's end and
/// the process's termination close it.
@Suite(.timeLimit(.minutes(1)))
struct PublicationLedgerRunTests {
    private let link = FakeLink()
    private func makeLedger() async -> PublicationLedger {
        await .make(link: link)
    }

    private static let four: CatalogState = .loaded(makeCatalog(4))
    private static let half: CatalogState = .loaded(makeCatalog(4).prefix(2))

    // MARK: Publication and liveness

    @Test
    func test_publishRun_numbersItWithTheCatalog_andALaterCatalogKeepsIt() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(2)), at: linkNow)

        let outcome = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        let written = try link.writtenStates()
        #expect(outcome == .written(written[1]))
        #expect(written[1].sequence == 2)
        #expect(written[1].run == makeRun())
        #expect(written[1].isRunLive)
        #expect(written[1].catalog == .loaded(makeCatalog(2)))

        _ = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(3)), at: linkNow)

        let afterCatalog = try #require(try link.writtenStates().last)
        #expect(afterCatalog.catalog == .loaded(makeCatalog(3)))
        #expect(afterCatalog.run == makeRun())
        // The catalog kept the run's revision, so the timer's answer on it is still live.
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow).isRunLive)
    }

    @Test
    func test_reply_answeredBy_isLiveOnlyForTheOpenOwnerAtTheAnsweredRevisionOrNewer() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)
        _ = await ledger.publishRun(revision: 5, run: makeRun(stage: "A"), at: linkNow)
        _ = await ledger.publishRun(revision: 6, run: makeRun(stage: "B"), at: linkNow)
        let digest = try WatchCatalog.digest(of: .loaded(makeCatalog(1)))
        let isLive = { (answer: (owner: UUID, revision: Int)?) in
            ledger.reply(knownCatalogDigest: digest, answeredBy: answer, at: linkNow).isRunLive
        }

        // The timer answered 5 and published 6 before the reply: its own later content is live.
        #expect(isLive((owner(1), 5)))
        #expect(isLive((owner(1), 6)))
        #expect(!isLive((owner(1), 7)))
        #expect(!isLive((owner(2), 6)))
        #expect(!isLive(nil))

        let confirming = ledger.reply(knownCatalogDigest: digest, answeredBy: (owner(1), 6), at: linkNow)
        #expect(confirming.catalog == nil)
        #expect(confirming.run == makeRun(stage: "B"))
        #expect(confirming.sequence == 3)
        let full = ledger.reply(knownCatalogDigest: "other", answeredBy: (owner(1), 6), at: linkNow)
        #expect(full.catalog == .loaded(makeCatalog(1)))
        #expect(full.run == makeRun(stage: "B"))

        ledger.markEnded(owner(1))
        #expect(!isLive((owner(1), 6)))
    }

    @Test
    func test_reply_gateClosed_isNotLive() async {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        ledger.closeGate()

        #expect(!ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow).isRunLive)
    }

    @Test
    func test_publishRun_sameContentNewerRevision_skipsAndStaysLiveForIt() async {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        let again = await ledger.publishRun(revision: 2, run: makeRun(), at: linkNow)

        #expect(again == .skipped)
        #expect(link.offered.value.count == 1)
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 2), at: linkNow).isRunLive)
    }

    @Test
    func test_publishRun_olderRevision_isSkipped_andCatalogRevisionsCountApart() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 3, run: makeRun(stage: "A"), at: linkNow)

        let older = await ledger.publishRun(revision: 2, run: makeRun(stage: "B"), at: linkNow)
        let catalog = await ledger.publish(revision: 1, catalog: .loaded(makeCatalog(1)), at: linkNow)

        #expect(older == .skipped)
        guard case let .written(state) = catalog else {
            Issue.record("A catalog of revision 1 after a run of revision 3 was not written: \(catalog)")
            return
        }
        #expect(state.run == makeRun(stage: "A"))
    }

    // MARK: Room for the run

    @Test
    func test_publishRun_ordinaryRun_fitsWithTheWholeCut() async throws {
        let ledger = await makeLedger()
        let large = makeCatalog(200) { "Workout \($0) " + String(repeating: "x", count: 400) }
        _ = await ledger.publish(revision: 1, catalog: .loaded(large), at: linkNow)
        let cut = try #require(try link.writtenStates().first?.catalog)

        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A"), at: linkNow)
        _ = await ledger.publishRun(revision: 2, run: makeRun(stage: "B"), at: linkNow)

        // The reserve keeps the cut the same with a run and from stage to stage.
        #expect(try link.writtenStates().catalogs == [cut, cut, cut])
    }

    @Test
    func test_publishRun_runLargerThanTheReserve_takesAShorterCatalog_andTheListComesBackWhole() async throws {
        let ledger = await makeLedger()
        let large = makeCatalog(200) { "Workout \($0) " + String(repeating: "x", count: 400) }
        _ = await ledger.publish(revision: 1, catalog: .loaded(large), at: linkNow)
        let cut = try #require(try link.writtenStates().first?.catalog)
        guard case let .loaded(cutList) = cut else {
            Issue.record("The large catalog was not cut to a list")
            return
        }

        _ = await ledger.publishRun(revision: 1, run: makeRun(nameLength: 9_000), at: linkNow)
        let withRun = try #require(try link.writtenStates().last)
        #expect(withRun.run == makeRun(nameLength: 9_000))
        #expect(withRun.catalog == .loaded(cutList.prefix(cutList.entries.count / 2)))
        #expect(!withRun.isRunTooLarge)

        _ = await ledger.end(owner: owner(1), at: linkNow)
        let ended = try #require(try link.writtenStates().last)
        #expect(ended.run == nil)
        #expect(ended.catalog == cut)
    }

    @Test
    func test_publishRun_everyCandidateRefused_hidesTheRunUntilAnotherOwnerPublishes() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])

        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)

        let hidden = try #require(try link.writtenStates().last)
        #expect(hidden.run == nil)
        #expect(hidden.isRunTooLarge)
        #expect(hidden.catalog == Self.four)

        // The same owner's next stage stays hidden, so the watch does not flicker between stages that fit and not.
        let offeredBefore = link.offered.value.count
        #expect(await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow) == .skipped)
        #expect(link.offered.value.count == offeredBefore)

        _ = await ledger.publishRun(revision: 3, run: makeRun(owner: 2), at: linkNow)
        let other = try #require(try link.writtenStates().last)
        #expect(other.run == makeRun(owner: 2))
        #expect(!other.isRunTooLarge)
    }

    @Test
    func test_tooLargeRun_catalogChangeKeepsTheFlag_endClearsIt() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        let offeredBefore = link.offered.value.count

        _ = await ledger.publish(revision: 2, catalog: .loaded(makeCatalog(3)), at: linkNow)

        let changed = try #require(try link.writtenStates().last)
        #expect(changed.catalog == .loaded(makeCatalog(3)))
        #expect(changed.run == nil)
        #expect(changed.isRunTooLarge)
        // The hidden run was not offered again with the new catalog.
        #expect(link.offered.value.dropFirst(offeredBefore).allSatisfy { $0.run == nil })

        _ = await ledger.end(owner: owner(1), at: linkNow)
        #expect(try link.writtenStates().last?.isRunTooLarge == false)
    }

    @Test
    func test_publishRun_everyWriteRefused_keepsTheOlderRunWhichIsNotLiveForTheNewRevision() async {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)
        // Refused with the run, then the state without it is refused too.
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge])

        let outcome = await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow)

        #expect(outcome == .skipped)
        #expect(!ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 2), at: linkNow).isRunLive)
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: nil, at: linkNow).run == makeRun(stage: "A1"))
    }

    @Test
    func test_publishRun_failedWrite_isPendingAndLatest_untilWriteLatestAndSendWritesIt() async throws {
        let ledger = await makeLedger()
        link.snapshot.withValue { $0.canPublish = false }

        let outcome = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        guard case let .pending(state) = outcome else {
            Issue.record("A run that could not be written was not pending: \(outcome)")
            return
        }
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow).run == makeRun())
        #expect(link.contexts.value.isEmpty)

        link.snapshot.withValue { $0.canPublish = true }
        ledger.writeLatestAndSend()
        await ledger.settle()
        // The pending state itself is written: nothing new is numbered or sent.
        #expect(try link.writtenStates() == [state])
        #expect(link.messages.value.isEmpty)
    }

    // MARK: Memory of refusals

    @Test
    func test_refusalWithARun_skipsThatCandidateForTheOwnersNextStage_untilTheWatchChanges() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)
        #expect(link.offeredStates().dropFirst().catalogs == [Self.four, Self.half])

        // The next stage starts after the refused candidate: one offer, not two.
        _ = await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow)
        #expect(link.offeredStates().dropFirst(3).catalogs == [Self.half])

        ledger.watchChanged()
        _ = await ledger.publishRun(revision: 3, run: makeRun(stage: "A3"), at: linkNow)
        #expect(link.offeredStates().dropFirst(4).catalogs == [Self.four])
        #expect(try link.writtenStates().last?.catalog == Self.four)
    }

    @Test
    func test_refusalWithARun_newCatalog_isOfferedWholeAgain() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)
        let five: CatalogState = .loaded(makeCatalog(5))

        _ = await ledger.publish(revision: 2, catalog: five, at: linkNow)
        let offeredBefore = link.offered.value.count
        _ = await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow)

        #expect(link.offeredStates().dropFirst(offeredBefore).catalogs == [five])
    }

    @Test
    func test_end_numbersTheStateWithoutTheRun_andTheLedgerKnowsNoRunOwner() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        #expect(ledger.runOwner() == owner(1))

        let outcome = await ledger.end(owner: owner(1), at: linkNow)

        guard case let .written(state) = outcome else {
            Issue.record("The state without the run was not written: \(outcome)")
            return
        }
        #expect(state.run == nil)
        #expect(ledger.runOwner() == nil)
        #expect(await ledger.end(owner: owner(1), at: linkNow) == .skipped)
    }

    @Test
    func test_refusalWithARun_holdsOnlyForItsOwner() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(owner: 1), at: linkNow)

        // Without the run the whole list fits again.
        _ = await ledger.end(owner: owner(1), at: linkNow)
        #expect(try link.writtenStates().last?.catalog == Self.four)
        #expect(try link.writtenStates().last?.run == nil)

        // Another owner starts from the whole list too.
        let offeredBefore = link.offered.value.count
        _ = await ledger.publishRun(revision: 2, run: makeRun(owner: 2), at: linkNow)
        #expect(link.offeredStates().dropFirst(offeredBefore).catalogs == [Self.four])
    }

    @Test
    func test_refusalWithoutARun_holdsForEveryLaterState() async throws {
        let ledger = await makeLedger()
        link.refusals.setValue([FakeLink.tooLarge])
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        #expect(try link.writtenStates().catalogs == [Self.half])

        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        // Refused without a run, the whole list is not offered with one.
        #expect(link.offeredStates().dropFirst(2).catalogs == [Self.half])
    }

    // MARK: The owner's end and termination

    @Test
    func test_writeLatestAndSend_ownerEndedBeforeItsEnd_writesAndSendsTheStateWithoutTheRun() async throws {
        let ledger = await makeLedger()
        link.snapshot.withValue { $0.canPublish = false }
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        ledger.markEnded(owner(1))
        link.snapshot.withValue { $0.canPublish = true }

        ledger.writeLatestAndSend()
        let end = await ledger.end(owner: owner(1), at: linkNow)

        let written = try link.writtenStates()
        #expect(written.count == 1)
        #expect(written.first?.run == nil)
        #expect(written.first?.catalog == Self.four)
        #expect(try link.sentStates() == written)
        // The state without the run is numbered once.
        #expect(end == .skipped)
    }

    @Test
    func test_finishTermination_unwrittenStateWithoutTheRun_isWritten() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)
        link.snapshot.withValue { $0.canPublish = false }
        _ = await ledger.end(owner: owner(1), at: linkNow)
        link.snapshot.withValue { $0.canPublish = true }

        let outcome = await ledger.finishTermination(at: linkNow)

        guard case let .written(state) = outcome else {
            Issue.record("The watch's context kept the run: \(outcome)")
            return
        }
        #expect(state.run == nil)
        #expect(try link.writtenStates().last == state)
    }

    @Test
    func test_finishTermination_writtenStateWithoutARun_isSkipped() async {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)

        #expect(await ledger.finishTermination(at: linkNow) == .skipped)
        #expect(link.contexts.value.count == 1)
    }

    @Test
    func test_finishTermination_tooLargeRun_writesTheStateWithoutTheFlag() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.refusals.setValue([FakeLink.tooLarge, FakeLink.tooLarge, FakeLink.tooLarge])
        _ = await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow)

        _ = await ledger.finishTermination(at: linkNow)

        let last = try #require(try link.writtenStates().last)
        #expect(last.run == nil)
        #expect(!last.isRunTooLarge)
    }

    @Test
    func test_closeGate_skipsEveryPublication_andOnlyTheTerminalStateIsWritten() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)

        ledger.closeGate()

        #expect(await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow) == .skipped)
        #expect(await ledger.publish(revision: 1, catalog: Self.four, at: linkNow) == .skipped)
        ledger.writeLatestAndSend()
        await ledger.settle()
        #expect(link.contexts.value.count == 1)
        #expect(link.messages.value.isEmpty)

        _ = await ledger.finishTermination(at: linkNow)
        let written = try link.writtenStates()
        #expect(written.count == 2)
        #expect(written.last?.run == nil)
    }

    // MARK: Races, driven by a write held on the ledger's queue

    /// A catalog section is trying the run with its first candidate when the owner ends: the next candidate finds the
    /// mark under the lock and the section starts again without the run.
    @Test
    func test_markEnded_whileACatalogSectionTriesTheRun_restartsItWithoutTheRun() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)
        let five: CatalogState = .loaded(makeCatalog(5))
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        link.refusals.setValue([FakeLink.tooLarge])
        let publication = Task { await ledger.publish(revision: 2, catalog: five, at: linkNow) }
        await gate.started.wait { $0 }
        #expect(link.offeredStates().last?.run == makeRun(stage: "A1"))

        ledger.markEnded(owner(1))
        gate.open()
        _ = await publication.value

        let last = try #require(try link.writtenStates().last)
        #expect(last.run == nil)
        #expect(last.catalog == five)
        #expect(!ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow).isRunLive)
    }

    @Test
    func test_markEnded_whileTheRunsWriteIsRefused_restartsWithTheWholeListWithoutTheRun() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        _ = await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow)
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        link.refusals.setValue([FakeLink.tooLarge])
        let publication = Task { await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow) }
        await gate.started.wait { $0 }

        ledger.markEnded(owner(1))
        gate.open()
        _ = await publication.value

        let written = try link.writtenStates()
        #expect(!written.contains { $0.run == makeRun(stage: "A2") })
        #expect(written.last?.run == nil)
        #expect(written.last?.catalog == Self.four)
        // No state the ledger took on carries A2 either.
        #expect(ledger.reply(knownCatalogDigest: nil, answeredBy: nil, at: linkNow).run == nil)
        // The refused candidate took a number of its own, so the written numbers increase but skip it.
        #expect(written.map(\.sequence) == written.map(\.sequence).sorted())
        #expect(Set(written.map(\.sequence)).count == written.count)
    }

    /// The gate closes while a section is trying its first candidate: the next candidate finds it closed under the lock
    /// and numbers nothing. The context already holds the state without the run, so termination has nothing to write.
    @Test
    func test_closeGate_whileASectionTriesACandidate_numbersNothing_andTerminationHasNothingToWrite() async throws {
        let ledger = await makeLedger()
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        link.refusals.setValue([FakeLink.tooLarge])
        let publication = Task { await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow) }
        await gate.started.wait { $0 }

        ledger.closeGate()
        gate.open()

        #expect(await publication.value == .skipped)
        #expect(try link.writtenStates().map(\.run) == [nil])
        _ = await ledger.finishTermination(at: linkNow)
        #expect(try link.writtenStates().count == 1)
        #expect(try link.writtenStates().last?.run == nil)
    }

    @Test
    func test_heldWrite_replyReturnsWhileTheQueueIsBlocked_andRunsNumberInRevisionOrder() async throws {
        let ledger = await makeLedger()
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        let first = Task { await ledger.publishRun(revision: 1, run: makeRun(stage: "A1"), at: linkNow) }
        await gate.started.wait { $0 }
        let second = Task { await ledger.publishRun(revision: 2, run: makeRun(stage: "A2"), at: linkNow) }

        // The queue is blocked inside a write; a reply reads the lock only. The second publication may reach the
        // queue before or after the release: either way it is numbered after the first.
        _ = ledger.reply(knownCatalogDigest: nil, answeredBy: (owner(1), 1), at: linkNow)
        gate.open()
        _ = await first.value
        _ = await second.value

        let written = try link.writtenStates()
        #expect(written.map(\.run) == [makeRun(stage: "A1"), makeRun(stage: "A2")])
        #expect(written.map(\.sequence) == [1, 2])
    }

    @Test
    func test_writeLatestAndSend_queuedBehindASection_runsAfterIt() async throws {
        let ledger = await makeLedger()
        link.snapshot.withValue { $0.canPublish = false }
        _ = await ledger.publish(revision: 1, catalog: Self.four, at: linkNow)
        link.snapshot.withValue { $0.canPublish = true }
        let gate = WriteGate()
        defer { gate.open() }
        link.gate.setValue(gate)
        let publication = Task { await ledger.publishRun(revision: 1, run: makeRun(), at: linkNow) }
        await gate.started.wait { $0 }

        ledger.writeLatestAndSend()
        gate.open()
        _ = await publication.value
        await ledger.settle()

        // The run's section wrote the newer state first, so the queued rewrite found nothing left to write or send.
        #expect(try link.writtenStates().map(\.run) == [makeRun()])
        #expect(link.offered.value.count == 1)
        #expect(link.messages.value.isEmpty)
    }
}
