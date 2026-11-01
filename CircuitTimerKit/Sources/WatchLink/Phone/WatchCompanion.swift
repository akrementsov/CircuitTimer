import Foundation
import os

/// The iPhone's side of the link, one per process. It answers the watch's requests from the newest published state,
/// also in a process a request launched, which has no `Store` and has not read the workouts: such a process answers
/// that it knows no catalog, and the list reaches the watch when the app publishes it.
actor WatchCompanion {
    private let ledger: PublicationLedger
    private let transport: LinkTransport
    private let now: @Sendable () -> Date

    init(ledger: PublicationLedger, transport: LinkTransport, now: @escaping @Sendable () -> Date) {
        self.ledger = ledger
        self.transport = transport
        self.now = now
    }

    func run(_ events: AsyncStream<SessionEvent>) async {
        for await event in events {
            switch event {
                case .activated, .statusChanged:
                    if let fallback = await ledger.writeLatest() {
                        push(fallback)
                    }
                case .watchChanged:
                    await ledger.watchChanged()
                case let .request(data, ticket):
                    await answer(data, through: ticket)
                case .context, .message:
                    // The watch sends neither.
                    Logger.watchLink.error("The iPhone received a context or a message from the watch")
            }
        }
    }

    func publishCatalog(revision: Int, catalog: CatalogState) async {
        push(await ledger.publish(revision: revision, catalog: catalog, at: now()))
    }

    func publishRun(revision: Int, run: WatchRun) async {
        push(await ledger.publishRun(revision: revision, run: run, at: now()), withCatalog: false)
    }

    /// Stops publishing the owner's run at once, without waiting for an actor hop or the queue.
    nonisolated func markEnded(_ owner: UUID) {
        ledger.markEnded(owner)
    }

    /// Numbers the state without the owner's run and sends it to an open watch.
    func end(owner: UUID) async {
        push(await ledger.end(owner: owner, at: now()), withCatalog: false)
    }

    /// Stops every publication synchronously, for termination.
    nonisolated func closeGate() {
        ledger.closeGate()
    }

    /// Writes the last state, without any run, and sends it to an open watch.
    func finishTermination() async {
        push(await ledger.finishTermination(at: now()), withCatalog: false)
    }

    private func push(_ outcome: PublishOutcome, withCatalog: Bool = true) {
        switch outcome {
            case let .written(state), let .pending(state):
                push(withCatalog ? state : state.withoutCatalog)
            case .skipped:
                break
        }
    }

    /// An open watch app gets the state at once; a closed one reads the context when it opens.
    private func push(_ state: PhoneState) {
        guard transport.status().isReachable else { return }
        do {
            transport.sendMessage(try WireCoding.encode(state))
        } catch {
            Logger.watchLink.error("A state did not encode: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func answer(_ data: Data, through ticket: ReplyTicket) async {
        let reply: WatchReplyEnvelope
        if WireCoding.schemaVersion(of: data) == WatchLinkSchema.version,
           let envelope = Self.decodeRequest(data) {
            switch envelope.request {
                case let .refresh(knownCatalogDigest):
                    let state = ledger.reply(knownCatalogDigest: knownCatalogDigest, answeredBy: nil, at: now())
                    reply = WatchReplyEnvelope(requestID: envelope.requestID, reply: .state(state))
            }
        } else {
            reply = .unreadable
        }
        do {
            ticket.reply(try WireCoding.encode(reply))
        } catch {
            Logger.watchLink.error("A reply did not encode: \(String(reflecting: error), privacy: .public)")
            ticket.reply(Data())
        }
    }

    private static func decodeRequest(_ data: Data) -> WatchRequestEnvelope? {
        do {
            return try WireCoding.decode(WatchRequestEnvelope.self, from: data)
        } catch {
            Logger.watchLink.error("A request of our version did not decode: \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }
}

private extension PhoneState {
    /// The state as a message about the run carries it: the catalog stays in the context and in replies, the digest
    /// tells the watch whether its list is still current.
    var withoutCatalog: PhoneState {
        PhoneState(
            processID: processID,
            sequence: sequence,
            publishedAt: publishedAt,
            catalog: nil,
            catalogDigest: catalogDigest,
            run: run,
            isRunLive: isRunLive,
            isRunTooLarge: isRunTooLarge
        )
    }
}
