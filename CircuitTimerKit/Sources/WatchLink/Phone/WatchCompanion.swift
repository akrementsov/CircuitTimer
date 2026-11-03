import Foundation
import os
import WorkoutActivity
import WorkoutDomain

/// The iPhone's side of the link, one per process. It answers the watch's requests from the newest published state,
/// also in a process a request launched, which has no `Store` and has not read the workouts: such a process answers
/// that it knows no catalog, and the list reaches the watch when the app publishes it. A request about a running
/// workout goes to its timer first, so a reply confirms a run only after its timer settled and published it. A command
/// goes to the timer the same way and is answered once, with what the timer did and the state it published.
actor WatchCompanion {
    /// How long a request waits for the timer, counted from its arrival; then the reply says the run is not live.
    static let timerWait: Duration = .seconds(5)

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
    private let commands = CommandGate()
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

    /// Stops every publication and every command synchronously, for termination.
    nonisolated func closeGate() {
        commands.close()
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

    /// The timer's answer to a command, after the syncs its rules wait for. A command still waiting gets it; one that
    /// already gave up leaves the publication to this call.
    func controlHandled(
        owner: UUID,
        requestID: Int,
        result: LiveActivityControlResult,
        publication: WatchRunPublication?
    ) async {
        if commands.answer(requestID: requestID, owner: owner, CommandAnswer(result: result, publication: publication)) {
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

    /// Also what a replaced stream's late termination calls; internal so tests can make that call at a known point.
    func subscriptionEnded(owner: UUID, subscriptionID: Int) {
        guard subscriptions[owner]?.id == subscriptionID else { return }
        subscriptions[owner]?.continuation.finish()
        subscriptions[owner] = nil
        for (id, ticket) in tickets where ticket.owner == owner && ticket.subscriptionID == subscriptionID {
            tickets[id] = nil
            ticket.answer.give(nil)
        }
        commands.endSubscription(owner: owner, subscriptionID: subscriptionID)
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
                case let .control(owner, command, generation, knownCatalogDigest):
                    let (result, state) = await commandState(
                        owner: owner,
                        command: command,
                        generation: generation,
                        knownCatalogDigest: knownCatalogDigest,
                        arrival: arrival
                    )
                    reply = WatchReplyEnvelope(requestID: envelope.requestID, reply: .control(result, state))
                case let .start(_, _, knownCatalogDigest):
                    // Without an app subscriber there is no foreground Start flow to admit the request.
                    reply = WatchReplyEnvelope(
                        requestID: envelope.requestID,
                        reply: .start(.openPhoneApp, notLive(knownCatalogDigest: knownCatalogDigest))
                    )
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
    /// `timerWait` of the request's arrival.
    private func refreshState(knownCatalogDigest: String?, arrival: MonotonicInstant) async -> PhoneState {
        let notLive = { self.notLive(knownCatalogDigest: knownCatalogDigest) }
        // A request whose 5 s already passed before its task ran goes to no timer.
        guard remaining(since: arrival) > .zero, let owner = ledger.runOwner(), let subscription = subscriptions[owner] else {
            return notLive()
        }

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
        return await liveState(owner: owner, publication: publication, knownCatalogDigest: knownCatalogDigest, arrival: arrival)
    }

    /// The reply to a command. `applied` and `stale` come only with the live state the timer published for them;
    /// without it in time the iPhone does not know what the watch should show, so the result is `timedOut`. A command
    /// the timer may have applied is never answered as refused. Internal so a test can pass an arrival already past the
    /// wait, which no event can order before the task starts.
    func commandState(
        owner requested: UUID,
        command: LiveActivityCommand,
        generation: Int,
        knownCatalogDigest: String?,
        arrival: MonotonicInstant
    ) async -> (WatchControlResult, PhoneState) {
        let notLive = { self.notLive(knownCatalogDigest: knownCatalogDigest) }
        guard remaining(since: arrival) > .zero, let owner = ledger.runOwner(), owner == requested,
              !ledger.isEnded(owner), let subscription = subscriptions[owner] else {
            return (.unavailable, notLive())
        }

        requestSerial += 1
        let request = WatchControlRequest(id: requestSerial, kind: .command(command, generation: generation))
        let answer: OneAnswer<CommandAnswer?>
        switch commands.admit(request, owner: owner, subscriptionID: subscription.id, into: subscription.continuation) {
            case let .admitted(admitted):
                answer = admitted
            case .closed:
                return (.unavailable, notLive())
            case .dropped:
                // The timer did not get it, but it lives: the watch asks again instead of reporting a failure.
                Logger.watchLink.notice("A command did not fit the timer's request buffer")
                return (.timedOut, notLive())
            case .terminated:
                subscriptionEnded(owner: owner, subscriptionID: subscription.id)
                return (.unavailable, notLive())
        }
        guard let given = await answer.wait(timeout: remaining(since: arrival), clock: clock, otherwise: nil) else {
            commands.withdraw(requestID: request.id)
            Logger.watchLink.notice("The timer did not answer a command within its wait")
            return (.timedOut, notLive())
        }
        let result = WatchControlResult(given.result)
        let isApplied = result == .applied || result == .stale
        guard let publication = given.publication, publication.run.owner == owner else {
            // A timer that applied the command and closed before publishing: the watch cannot be told what it did.
            return (isApplied ? .timedOut : result, notLive())
        }
        let state = await liveState(owner: owner, publication: publication, knownCatalogDigest: knownCatalogDigest, arrival: arrival)
        return (isApplied && !state.isRunLive ? .timedOut : result, state)
    }

    /// Numbers the timer's publication and replies with it: live only if the ledger holds it, or a newer one of the
    /// same timer, within the request's wait.
    private func liveState(
        owner: UUID,
        publication: WatchRunPublication,
        knownCatalogDigest: String?,
        arrival: MonotonicInstant
    ) async -> PhoneState {
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
        // A wait with nothing left returns what was already given, so the bound is checked again after it.
        guard await published.wait(timeout: remaining(since: arrival), clock: clock, otherwise: false),
              remaining(since: arrival) > .zero else {
            return notLive(knownCatalogDigest: knownCatalogDigest)
        }
        // Live only if the ledger holds this publication or a newer one of the same timer, checked as the reply is
        // built: content a refused write left behind is not this answer's run.
        return ledger.reply(
            knownCatalogDigest: knownCatalogDigest,
            answeredBy: (owner: owner, revision: publication.revision),
            at: now()
        )
    }

    /// The newest state, read under the ledger's lock without waiting for its queue.
    private func notLive(knownCatalogDigest: String?) -> PhoneState {
        ledger.reply(knownCatalogDigest: knownCatalogDigest, answeredBy: nil, at: now())
    }

    private func remaining(since arrival: MonotonicInstant) -> Duration {
        max(.zero, Self.timerWait - (arrival.duration(toNowOf: clock) ?? Self.timerWait))
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
