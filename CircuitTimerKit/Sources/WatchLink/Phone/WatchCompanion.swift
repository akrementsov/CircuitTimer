import Foundation
import os
import WorkoutDomain

/// The iPhone's side of the link, one per process. It answers the watch's requests from the newest published state,
/// also in a process a request launched, which has no `Store` and has not read the workouts: such a process answers
/// that it knows no catalog, and the list reaches the watch when the app publishes it. A request about a running
/// workout goes to its timer first, so a reply confirms a run only after its timer settled and published it.
actor WatchCompanion {
    /// How long a request waits for the timer, counted from its arrival; then the reply says the run is not live.
    static let refreshWait: Duration = .seconds(5)

    private struct Subscription {
        let id: Int
        let continuation: AsyncStream<WatchControlRequest>.Continuation
    }

    private struct Ticket {
        let owner: UUID
        let subscriptionID: Int
        let answer: OneAnswer<WatchRunPublication?>
    }

    private let ledger: PublicationLedger
    private let transport: LinkTransport
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private var subscriptions: [UUID: Subscription] = [:]
    private var tickets: [Int: Ticket] = [:]
    private var subscriptionSerial = 0
    private var requestSerial = 0

    init(
        ledger: PublicationLedger,
        transport: LinkTransport,
        now: @escaping @Sendable () -> Date,
        clock: any Clock<Duration>
    ) {
        self.ledger = ledger
        self.transport = transport
        self.now = now
        self.clock = clock
    }

    /// Writes go to the ledger's queue in the order of their events; a request is answered in a task of its own, so
    /// its wait for the timer holds no other event.
    func run(_ events: AsyncStream<SessionEvent>) async {
        await withDiscardingTaskGroup { group in
            for await event in events {
                switch event {
                    case .activated, .statusChanged:
                        ledger.writeLatest { [self] fallback in
                            if let fallback { push(fallback) }
                        }
                    case .watchChanged:
                        ledger.watchChanged()
                    case let .request(data, ticket):
                        // The 5 s count from here, not from when the answering task gets to run.
                        let arrival = MonotonicInstant(now: clock)
                        group.addTask { await self.answer(data, through: ticket, arrival: arrival) }
                    case .context, .message:
                        // The watch sends neither.
                        Logger.watchLink.error("The iPhone received a context or a message from the watch")
                }
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

    /// Answers the owner's waiting requests as not live, then numbers the state without its run and sends it to an
    /// open watch.
    func end(owner: UUID) async {
        endRequests(of: owner)
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

    /// The timer's stream of requests. A new subscription of the same owner replaces the old one, whose waiting
    /// requests are answered as not live.
    func controlRequests(owner: UUID) -> AsyncStream<WatchControlRequest> {
        // A timer that subscribes after its end gets nothing to wait on.
        guard !ledger.isEnded(owner) else { return AsyncStream { $0.finish() } }
        if let old = subscriptions[owner] {
            subscriptionEnded(owner: owner, subscriptionID: old.id)
        }
        subscriptionSerial += 1
        let subscriptionID = subscriptionSerial
        let pair = AsyncStream<WatchControlRequest>.makeStream(bufferingPolicy: .bufferingOldest(4))
        pair.continuation.onTermination = { [weak self] _ in
            // Stream termination is synchronous; only actor housekeeping escapes its callback.
            // swiftlint:disable:next no_unstructured_task
            Task { await self?.subscriptionEnded(owner: owner, subscriptionID: subscriptionID) }
        }
        subscriptions[owner] = Subscription(id: subscriptionID, continuation: pair.continuation)
        return pair.stream
    }

    /// The timer's answer: its settled run, or `nil` when it cannot publish one. A request still waiting publishes it
    /// and replies; one that already gave up leaves the publication to this call.
    func refreshHandled(owner: UUID, requestID: Int, publication: WatchRunPublication?) async {
        if let ticket = tickets[requestID], ticket.owner == owner, ticket.answer.give(publication) {
            return
        }
        guard let publication, publication.run.owner == owner else { return }
        await publishRun(revision: publication.revision, run: publication.run)
    }

    private func endRequests(of owner: UUID) {
        if let subscription = subscriptions[owner] {
            subscriptionEnded(owner: owner, subscriptionID: subscription.id)
        }
    }

    private func subscriptionEnded(owner: UUID, subscriptionID: Int) {
        guard subscriptions[owner]?.id == subscriptionID else { return }
        subscriptions[owner]?.continuation.finish()
        subscriptions[owner] = nil
        for (id, ticket) in tickets where ticket.owner == owner && ticket.subscriptionID == subscriptionID {
            tickets[id] = nil
            ticket.answer.give(nil)
        }
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
    nonisolated private func push(_ state: PhoneState) {
        guard transport.status().isReachable else { return }
        do {
            transport.sendMessage(try WireCoding.encode(state))
        } catch {
            Logger.watchLink.error("A state did not encode: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func answer(_ data: Data, through ticket: ReplyTicket, arrival: MonotonicInstant) async {
        let reply: WatchReplyEnvelope
        if WireCoding.schemaVersion(of: data) == WatchLinkSchema.version,
           let envelope = Self.decodeRequest(data) {
            switch envelope.request {
                case let .refresh(knownCatalogDigest):
                    let state = await refreshState(knownCatalogDigest: knownCatalogDigest, arrival: arrival)
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

    /// The reply to a refresh: live only when the run's own timer answered and its publication was numbered within
    /// `refreshWait` of the request's arrival.
    private func refreshState(knownCatalogDigest: String?, arrival: MonotonicInstant) async -> PhoneState {
        let notLive = { self.ledger.reply(knownCatalogDigest: knownCatalogDigest, answeredBy: nil, at: self.now()) }
        guard let owner = ledger.runOwner(), let subscription = subscriptions[owner] else { return notLive() }

        requestSerial += 1
        let requestID = requestSerial
        let answer = OneAnswer<WatchRunPublication?>()
        tickets[requestID] = Ticket(owner: owner, subscriptionID: subscription.id, answer: answer)
        switch subscription.continuation.yield(WatchControlRequest(id: requestID, kind: .refresh)) {
            case .enqueued:
                break
            case .dropped:
                Logger.watchLink.error("A refresh did not fit the timer's request buffer")
                tickets[requestID] = nil
                return notLive()
            case .terminated:
                subscriptionEnded(owner: owner, subscriptionID: subscription.id)
                tickets[requestID] = nil
                return notLive()
            @unknown default:
                Logger.watchLink.error("A refresh could not be delivered to the timer")
                tickets[requestID] = nil
                return notLive()
        }
        let publication = await answer.wait(timeout: remaining(since: arrival), clock: clock, otherwise: nil)
        tickets[requestID] = nil
        guard let publication, publication.run.owner == owner else { return notLive() }

        // The publication is numbered before the reply, so the reply carries its own number; the write may outlive
        // the wait, which then answers as not live.
        let published = OneAnswer<Bool>()
        let publishedAt = now()
        // The write outlives a wait that gives up; it still numbers the run and sends it to an open watch.
        // swiftlint:disable:next no_unstructured_task
        Task {
            let outcome = await ledger.publishRun(revision: publication.revision, run: publication.run, at: publishedAt)
            published.give(true)
            push(outcome, withCatalog: false)
        }
        guard await published.wait(timeout: remaining(since: arrival), clock: clock, otherwise: false) else {
            return notLive()
        }
        // Live only if the ledger holds this publication or a newer one of the same timer, checked as the reply is
        // built: content a refused write left behind is not this answer's run.
        return ledger.reply(
            knownCatalogDigest: knownCatalogDigest,
            answeredBy: (owner: owner, revision: publication.revision),
            at: now()
        )
    }

    private func remaining(since arrival: MonotonicInstant) -> Duration {
        max(.zero, Self.refreshWait - (arrival.duration(toNowOf: clock) ?? Self.refreshWait))
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
