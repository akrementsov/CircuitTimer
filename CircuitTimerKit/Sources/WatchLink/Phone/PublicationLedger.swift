import Foundation
import os

enum PublishOutcome: Equatable, Sendable {
    /// Not newer than a publication already handled, or the same catalog already written.
    case skipped
    case written(PhoneState)
    /// Numbered but not written yet: no watch, an inactive session or a failed write. It is written again later.
    case pending(PhoneState)
}

/// The iPhone's published state. It numbers each state and writes the context in one section of its serial queue, so
/// the order of the numbers is the order of the writes and an older state never replaces a newer one. CT-9-3 writes
/// its termination state in a section of the same queue.
///
/// Every section is short and never waits for the main thread; callers await it without blocking a thread.
final class PublicationLedger: @unchecked Sendable {
    // Unchecked: every stored variable below is touched only on `queue`.
    private let queue = DispatchQueue(label: "WatchLink.PublicationLedger")
    private let processID: UUID
    private let transport: LinkTransport
    private var lastRevision = 0
    private var sequence = 0
    /// The newest numbered state, written or not.
    private var prepared: PhoneState?
    private var isWritten = false

    init(processID: UUID, transport: LinkTransport) {
        self.processID = processID
        self.transport = transport
    }

    /// Publishes the catalog of `revision` unless a newer revision was published. A catalog too large for one write
    /// is cut to what fits; if WatchConnectivity still refuses it, half of that; then `.unavailable(.tooLarge)`.
    func publish(revision: Int, catalog: CatalogState, at now: Date) async -> PublishOutcome {
        await onQueue { self.publishOnQueue(revision: revision, catalog: catalog, at: now) }
    }

    /// Writes the newest state again if its write did not happen, after activation or a change of watch.
    func writeLatest() async {
        await onQueue {
            guard let prepared = self.prepared, !self.isWritten else { return }
            self.isWritten = self.write(prepared) == .written
        }
    }

    /// The state to answer a request with: the catalog only if the watch's digest differs. A process that has not
    /// published yet knows no catalog and says so with a `nil` digest.
    func reply(knownCatalogDigest: String?, at now: Date) async -> PhoneState {
        await onQueue {
            guard let prepared = self.prepared else {
                return PhoneState(processID: self.processID, sequence: 0, publishedAt: now, catalog: nil, catalogDigest: nil)
            }
            guard prepared.catalogDigest != knownCatalogDigest else {
                return PhoneState(
                    processID: self.processID,
                    sequence: prepared.sequence,
                    publishedAt: prepared.publishedAt,
                    catalog: nil,
                    catalogDigest: prepared.catalogDigest
                )
            }
            return prepared
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

    private func publishOnQueue(revision: Int, catalog: CatalogState, at now: Date) -> PublishOutcome {
        guard revision > lastRevision else { return .skipped }
        lastRevision = revision
        var candidates = Self.fitted(catalog, processID: processID, at: now)
        while let candidate = candidates.first {
            candidates.removeFirst()
            guard let digest = Self.digest(of: candidate) else { continue }
            if digest == prepared?.catalogDigest, isWritten {
                return .skipped
            }
            sequence += 1
            let state = PhoneState(
                processID: processID,
                sequence: sequence,
                publishedAt: now,
                catalog: candidate,
                catalogDigest: digest
            )
            switch write(state) {
                case .written:
                    prepared = state
                    isWritten = true
                    return .written(state)
                case .pending:
                    prepared = state
                    isWritten = false
                    return .pending(state)
                case .tooLarge:
                    continue
            }
        }
        return .skipped
    }

    private func write(_ state: PhoneState) -> WriteResult {
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

    /// The catalog cut to the envelope limit, then half of that, then `.unavailable(.tooLarge)`: the order in which a
    /// refused write falls back.
    private static func fitted(_ catalog: CatalogState, processID: UUID, at now: Date) -> [CatalogState] {
        guard case let .loaded(full) = catalog else { return [catalog] }
        var low = 0
        var high = full.entries.count
        // The largest prefix whose state fits; an empty list always does.
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(.loaded(full.prefix(middle)), processID: processID, at: now) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let fitting = low == full.entries.count ? full : full.prefix(low)
        return [.loaded(fitting), .loaded(fitting.prefix(fitting.entries.count / 2)), .unavailable(.tooLarge)]
    }

    private static func fits(_ catalog: CatalogState, processID: UUID, at now: Date) -> Bool {
        // The largest number and a full digest: the real state is never longer.
        let probe = PhoneState(
            processID: processID,
            sequence: .max,
            publishedAt: now,
            catalog: catalog,
            catalogDigest: String(repeating: "0", count: 64)
        )
        do {
            return try WireCoding.encode(probe).count <= WatchLinkSchema.envelopeLimit
        } catch {
            Logger.watchLink.error("A catalog did not encode: \(String(reflecting: error), privacy: .public)")
            return false
        }
    }

    private static func digest(of catalog: CatalogState) -> String? {
        do {
            return try WatchCatalog.digest(of: catalog)
        } catch {
            Logger.watchLink.error("A catalog did not encode: \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }
}
