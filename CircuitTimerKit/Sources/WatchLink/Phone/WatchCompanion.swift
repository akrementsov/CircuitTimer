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
                    await ledger.writeLatest()
                case let .request(data, ticket):
                    await answer(data, through: ticket)
                case .context, .message:
                    // The watch sends neither.
                    Logger.watchLink.error("The iPhone received a context or a message from the watch")
            }
        }
    }

    func publishCatalog(revision: Int, catalog: CatalogState) async {
        let outcome = await ledger.publish(revision: revision, catalog: catalog, at: now())
        switch outcome {
            case let .written(state), let .pending(state):
                push(state)
            case .skipped:
                break
        }
    }

    /// An open watch app gets the list at once; a closed one reads the context when it opens.
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
                    let state = await ledger.reply(knownCatalogDigest: knownCatalogDigest, at: now())
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
