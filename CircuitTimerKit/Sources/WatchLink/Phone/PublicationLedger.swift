import Foundation
import os

enum PublishOutcome: Equatable, Sendable {
    /// Not newer than a publication already handled, of an owner that ended, after the gate closed, or the same
    /// state already written.
    case skipped
    case written(PhoneState)
    /// Numbered but not written yet: no watch, an inactive session or a failed write. It is written again later.
    case pending(PhoneState)
}

/// The iPhone's published state: the catalog and the running workout in one value. It numbers each state and writes
/// the context in one section of its serial queue, so the order of the numbers is the order of the writes and an
/// older state never replaces a newer one.
///
/// Every section is short and never waits for the main thread; callers await it without blocking a thread. What a
/// reply and the gates need is also kept under a lock, so a reply never waits for a context write.
final class PublicationLedger: @unchecked Sendable {
    /// What a reply reads and what closes publication, outside the queue.
    private struct Shared: Sendable {
        /// The newest numbered state whose write was decided: written, or pending.
        var latest: PhoneState?
        /// The revision of the run `latest` carries: the timer's own publication of it, or a newer one of the same
        /// content.
        var latestRunRevision: Int?
        var endedOwners: Set<UUID> = []
        var isGateClosed = false
    }

    // Unchecked: every stored variable below `shared` is touched only on `queue`.
    private let queue = DispatchQueue(label: "WatchLink.PublicationLedger")
    private let processID: UUID
    private let transport: LinkTransport
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var catalogRevision = 0
    private var runRevision = 0
    private var sequence = 0
    /// The newest numbered state, written or not.
    private var prepared: PhoneState?
    private var isWritten = false
    /// The catalog's candidates from its newest publication, in the order a refused write falls back. Every state
    /// starts from them, so a run that needs a shorter catalog does not shorten the list for later states.
    private var catalogCandidates: [CatalogState?] = [nil]
    /// How many leading candidates WatchConnectivity refused as too large without a run since the catalog was published
    /// or the watch changed: every later state skips them instead of encoding and offering them again.
    private var refusedCandidates = 0
    /// The same with a run: it holds only for that owner's states, as a list refused with a run may fit without it.
    private var refusedForRun: (owner: UUID, count: Int)?
    /// The owner whose run does not fit in a transfer; its runs are not published until it ends.
    private var tooLargeOwner: UUID?

    init(processID: UUID, transport: LinkTransport) {
        self.processID = processID
        self.transport = transport
    }

    /// Publishes the catalog of `revision` unless a newer revision was published. The catalog is cut to what fits with
    /// room for a run; if WatchConnectivity still refuses the state, half of that; then `.unavailable(.tooLarge)`.
    func publish(revision: Int, catalog: CatalogState, at now: Date) async -> PublishOutcome {
        await onQueue { self.publishCatalogOnQueue(revision: revision, catalog: catalog, at: now) }
    }

    /// Publishes the run of `revision` with the current catalog, unless a newer run was published or its owner ended.
    func publishRun(revision: Int, run: WatchRun, at now: Date) async -> PublishOutcome {
        await onQueue { self.publishRunOnQueue(revision: revision, run: run, at: now) }
    }

    /// Marks the owner ended at once: no section numbers its run from now on. `end(owner:at:)` then numbers the state
    /// without it.
    func markEnded(_ owner: UUID) {
        shared.withLock { _ = $0.endedOwners.insert(owner) }
    }

    /// Numbers the state without the run of `owner`, if it is the one published.
    func end(owner: UUID, at now: Date) async -> PublishOutcome {
        await onQueue {
            guard self.prepared?.run?.owner == owner || self.tooLargeOwner == owner else { return .skipped }
            self.tooLargeOwner = nil
            return self.commit(self.candidates(for: nil), run: nil, at: now)
        }
    }

    /// Closes publication synchronously, for termination: from now on only `finishTermination(at:)` writes.
    func closeGate() {
        shared.withLock { $0.isGateClosed = true }
    }

    /// Numbers and writes the state without any run, the last one this process writes.
    func finishTermination(at now: Date) async -> PublishOutcome {
        await onQueue {
            // A state without a run that was never written counts too: the watch must not keep a run its context
            // still holds.
            guard let prepared = self.prepared, prepared.run != nil || self.tooLargeOwner != nil || !self.isWritten else {
                return .skipped
            }
            self.tooLargeOwner = nil
            return self.commit(self.candidates(for: nil), run: nil, at: now, isTerminal: true)
        }
    }

    /// Writes the newest state again if its write did not happen, after activation or a change of watch. A state
    /// WatchConnectivity now refuses as too large falls back as a new publication would.
    /// Returns the state a fallback numbered, so an open watch can get it at once; `nil` when nothing new was numbered.
    func writeLatest() async -> PhoneState? {
        await withCheckedContinuation { continuation in
            writeLatest { continuation.resume(returning: $0) }
        }
    }

    /// `writeLatest()` for a caller that must enqueue it in order with other events without waiting.
    func writeLatest(then completion: @escaping @Sendable (PhoneState?) -> Void) {
        queue.async { completion(self.writeLatestOnQueue()) }
    }

    private func writeLatestOnQueue() -> PhoneState? {
        guard !isGateClosed, let prepared, !isWritten else { return nil }
        if let owner = prepared.run?.owner, !isOpen(for: owner) {
            // The owner ended before its own section ran: the state without its run replaces it.
            return numbered(commit(candidates(for: nil), run: nil, at: prepared.publishedAt))
        }
        switch write(prepared) {
            case .written:
                adopt(prepared, isWritten: true)
                return nil
            case .pending:
                return nil
            case .tooLarge:
                noteRefused(prepared.catalog, runOwner: prepared.run?.owner)
                let catalogs: [CatalogState?] = prepared.catalog.map(Self.fallbacks) ?? [nil]
                return numbered(commit(catalogs, run: prepared.run, at: prepared.publishedAt))
        }
    }

    private func numbered(_ outcome: PublishOutcome) -> PhoneState? {
        switch outcome {
            case let .written(state), let .pending(state):
                state
            case .skipped:
                nil
        }
    }

    /// The user switched to another watch: the context belongs to the watch it was written for, so the newest state
    /// is written again once the session for the new one activates.
    func watchChanged() {
        queue.async {
            self.isWritten = false
            self.refusedCandidates = 0
            self.refusedForRun = nil
        }
    }

    /// The owner of the run the newest decided state carries.
    func runOwner() -> UUID? {
        shared.withLock { $0.latest?.run?.owner }
    }

    func isEnded(_ owner: UUID) -> Bool {
        shared.withLock { $0.endedOwners.contains(owner) }
    }

    /// The state to answer a request with, without waiting for the queue: the catalog only if the watch's digest
    /// differs. The run is live only when its own timer answered: `answeredBy` is that timer's owner, still open, and
    /// the revision it answered with; the state must carry that publication or a newer one of the same timer, never an
    /// older one a refused write left. A process that has published nothing knows no catalog and says so with a `nil`
    /// digest.
    func reply(knownCatalogDigest: String?, answeredBy answer: (owner: UUID, revision: Int)?, at now: Date) -> PhoneState {
        shared.withLock { shared in
            guard let latest = shared.latest else {
                return PhoneState(processID: processID, sequence: 0, publishedAt: now, catalog: nil, catalogDigest: nil)
            }
            let isRunLive = answer.map { answer in
                latest.run?.owner == answer.owner
                    && (shared.latestRunRevision ?? .min) >= answer.revision
                    && !shared.isGateClosed
                    && !shared.endedOwners.contains(answer.owner)
            } ?? false
            // Answered now: the iPhone still had this list when it answered, whether it sends the list or confirms it.
            return PhoneState(
                processID: processID,
                sequence: latest.sequence,
                publishedAt: now,
                catalog: latest.catalogDigest == knownCatalogDigest ? nil : latest.catalog,
                catalogDigest: latest.catalogDigest,
                run: latest.run,
                isRunLive: isRunLive,
                isRunTooLarge: latest.isRunTooLarge
            )
        }
    }

    private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private enum WriteResult: Equatable {
        case written
        case pending
        case tooLarge
    }

    private var isGateClosed: Bool {
        shared.withLock { $0.isGateClosed }
    }

    private func isOpen(for owner: UUID) -> Bool {
        shared.withLock { !$0.isGateClosed && !$0.endedOwners.contains(owner) }
    }

    private func publishCatalogOnQueue(revision: Int, catalog: CatalogState, at now: Date) -> PublishOutcome {
        guard revision > catalogRevision else { return .skipped }
        catalogRevision = revision
        catalogCandidates = Self.fitted(catalog, processID: processID, at: now)
        refusedCandidates = 0
        refusedForRun = nil
        return commit(catalogCandidates, run: prepared?.run, at: now)
    }

    private func publishRunOnQueue(revision: Int, run: WatchRun, at now: Date) -> PublishOutcome {
        guard revision > runRevision, isOpen(for: run.owner) else { return .skipped }
        runRevision = revision
        // The timer publishes after every action: the same run costs no encoding, written or not; a write that did
        // not happen is written again on activation or a status change.
        if run == prepared?.run {
            shared.withLock { $0.latestRunRevision = revision }
            return .skipped
        }
        if let tooLargeOwner {
            // A run that did not fit stays hidden until its owner ends, so the watch does not flicker between stages
            // whose names fit and stages whose names do not.
            guard tooLargeOwner != run.owner else { return .skipped }
            self.tooLargeOwner = nil
        }
        return commit(candidates(for: run.owner), run: run, runRevision: revision, at: now)
    }

    private func noteRefused(_ catalog: CatalogState?, runOwner: UUID?) {
        guard let index = catalogCandidates.firstIndex(of: catalog) else { return }
        guard let runOwner else {
            refusedCandidates = max(refusedCandidates, index + 1)
            return
        }
        let counted = refusedForRun.flatMap { $0.owner == runOwner ? $0.count : nil } ?? 0
        refusedForRun = (owner: runOwner, count: max(counted, index + 1))
    }

    /// The catalog's candidates without those WatchConnectivity already refused for a state with the run of `owner`,
    /// or without a run; the last one always stays.
    private func candidates(for owner: UUID?) -> [CatalogState?] {
        let forRun = refusedForRun.flatMap { $0.owner == owner ? $0.count : nil } ?? 0
        let skipped = max(refusedCandidates, forRun)
        return Array(catalogCandidates.dropFirst(min(skipped, catalogCandidates.count - 1)))
    }

    /// Numbers and writes the first candidate WatchConnectivity does not refuse as too large; the run is dropped and
    /// its owner marked as too large when even the last catalog does not fit with it.
    private func commit(
        _ catalogs: [CatalogState?],
        run: WatchRun?,
        runRevision: Int? = nil,
        at now: Date,
        isTerminal: Bool = false
    ) -> PublishOutcome {
        guard isTerminal || !isGateClosed else { return .skipped }
        if let owner = tooLargeOwner, !isOpen(for: owner) {
            tooLargeOwner = nil
        }
        for catalog in catalogs {
            // Checked again before each candidate: a section that started before the owner ended must not number its
            // run. One that numbered it just before the mark is replaced by the owner's end section, and no reply
            // calls that run live.
            guard isTerminal || !isGateClosed else { return .skipped }
            if let run, !isOpen(for: run.owner) {
                // The state without the run starts again from the candidates refused without one, the whole list.
                return commit(candidates(for: nil), run: nil, at: now, isTerminal: isTerminal)
            }
            if let run, !Self.fits(catalog: catalog, run: run, processID: processID, at: now) {
                // A shorter catalog may still fit with the run; the run goes only when none does.
                continue
            }
            let digest: String?
            if let catalog {
                guard let encoded = Self.digest(of: catalog) else { continue }
                digest = encoded
            } else {
                digest = prepared?.catalogDigest
            }
            if isWritten, let prepared, prepared.catalogDigest == digest, prepared.run == run,
               prepared.isRunTooLarge == (tooLargeOwner != nil) {
                return .skipped
            }
            // Numbered under the lock that marks owners ended and closes the gate: a state is numbered before the
            // mark, and the owner's end section replaces it, or not at all.
            let isNumbered = shared.withLock { shared in
                guard isTerminal || !shared.isGateClosed else { return false }
                if let run, shared.endedOwners.contains(run.owner) { return false }
                self.sequence += 1
                return true
            }
            guard isNumbered else { return .skipped }
            let state = PhoneState(
                processID: processID,
                sequence: sequence,
                publishedAt: now,
                catalog: catalog,
                catalogDigest: digest,
                run: run,
                isRunLive: run != nil,
                isRunTooLarge: tooLargeOwner != nil
            )
            switch write(state, isTerminal: isTerminal) {
                case .written:
                    adopt(state, isWritten: true, runRevision: runRevision)
                    return .written(state)
                case .pending:
                    adopt(state, isWritten: false, runRevision: runRevision)
                    return .pending(state)
                case .tooLarge:
                    noteRefused(catalog, runOwner: run?.owner)
                    continue
            }
        }
        if let run, isOpen(for: run.owner) {
            // No catalog fits with the run, or WatchConnectivity refused every one: the run does not travel at all.
            markTooLarge(run.owner)
            return commit(catalogs, run: nil, at: now, isTerminal: isTerminal)
        }
        // Even `.unavailable(.tooLarge)` was refused, which a payload of a few hundred bytes should never be. The
        // context still holds the previous state, so replies keep answering with it rather than contradict it.
        return .skipped
    }

    private func adopt(_ state: PhoneState, isWritten: Bool, runRevision: Int? = nil) {
        prepared = state
        self.isWritten = isWritten
        shared.withLock { shared in
            shared.latest = state
            if state.run == nil {
                shared.latestRunRevision = nil
            } else if let runRevision {
                shared.latestRunRevision = runRevision
            }
        }
    }

    private func markTooLarge(_ owner: UUID) {
        guard tooLargeOwner != owner else { return }
        tooLargeOwner = owner
        Logger.watchLink.error("A running workout does not fit in a transfer; the watch shows that it runs on the iPhone")
    }

    private func write(_ state: PhoneState, isTerminal: Bool = false) -> WriteResult {
        guard isTerminal || !isGateClosed else { return .pending }
        let data: Data
        do {
            data = try WireCoding.encode(state)
        } catch {
            Logger.watchLink.error("A state did not encode: \(String(reflecting: error), privacy: .public)")
            return .pending
        }
        guard transport.status().canPublish else { return .pending }
        do {
            try transport.updateContext(data)
            return .written
        } catch {
            return PhoneLinkError(error) == .payloadTooLarge ? .tooLarge : .pending
        }
    }

    /// The catalog cut to the envelope limit less the run's reserve, then half of that, then
    /// `.unavailable(.tooLarge)`: the order in which a refused write falls back. A list of which not even one workout
    /// fits is too large, never an empty list. The reserve keeps the cut the same whether a run is published or not.
    private static func fitted(_ catalog: CatalogState, processID: UUID, at now: Date) -> [CatalogState?] {
        guard case let .loaded(full) = catalog else { return [catalog] }
        let limit = WatchLinkSchema.envelopeLimit - WatchLinkSchema.runReserve
        var low = 0
        var high = full.entries.count
        // The largest prefix whose state fits; an empty list always does.
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(catalog: .loaded(full.prefix(middle)), run: nil, processID: processID, at: now, limit: limit) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        guard low > 0 || full.entries.isEmpty else { return [.unavailable(.tooLarge)] }
        let fitting = low == full.entries.count ? full : full.prefix(low)
        return [.loaded(fitting)] + fallbacks(after: .loaded(fitting))
    }

    /// What follows a catalog WatchConnectivity refused as too large.
    private static func fallbacks(after catalog: CatalogState) -> [CatalogState?] {
        guard case let .loaded(refused) = catalog, refused.entries.count > 1 else { return [.unavailable(.tooLarge)] }
        return [.loaded(refused.prefix(refused.entries.count / 2)), .unavailable(.tooLarge)]
    }

    /// Whether the state fits in every reply envelope, with the largest number and a full digest. A refresh's reply,
    /// the context and a message carry less around the same state than the control and Start replies.
    static func fits(
        catalog: CatalogState?,
        run: WatchRun?,
        processID: UUID,
        at now: Date,
        limit: Int = WatchLinkSchema.envelopeLimit
    ) -> Bool {
        let probe = PhoneState(
            processID: processID,
            sequence: .max,
            publishedAt: now,
            catalog: catalog,
            catalogDigest: String(repeating: "0", count: 64),
            run: run,
            isRunLive: run != nil
        )
        do {
            let startResults: [WatchStartResult] = [
                .accepted(asksOnPhone: false),
                .accepted(asksOnPhone: true),
                .openPhoneApp,
                .busy,
                .listUnavailable,
                .changed,
                .gone,
                .notPlayable,
            ]
            let replies = [WatchReply.control(longestResult, probe)] + startResults.map { .start($0, probe) }
            return try replies.allSatisfy {
                try WireCoding.encode(WatchReplyEnvelope(requestID: processID, reply: $0)).count <= limit
            }
        } catch {
            Logger.watchLink.error("A state did not encode: \(String(reflecting: error), privacy: .public)")
            return false
        }
    }

    private static let longestResult = WatchControlResult.allCases.max { $0.rawValue.count < $1.rawValue.count } ?? .unavailable

    private static func digest(of catalog: CatalogState) -> String? {
        do {
            return try WatchCatalog.digest(of: catalog)
        } catch {
            Logger.watchLink.error("A catalog did not encode: \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }
}
