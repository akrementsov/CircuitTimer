import os

/// Admission and hand-over share termination's lock: no new Start reaches the app after this gate closes.
final class StartGate: Sendable {
    enum Admission {
        case admitted(OneAnswer<WatchStartResult?>)
        case busy
        case closed
        case noSubscriber
        case dropped
        case terminated
    }

    private struct Subscription {
        let id: Int
        let continuation: AsyncStream<WatchStartRequest>.Continuation
    }

    private struct Ticket {
        let requestID: Int
        let subscriptionID: Int
        let answer: OneAnswer<WatchStartResult?>
    }

    private struct Slots {
        var isClosed = false
        var serial = 0
        var subscription: Subscription?
        var ticket: Ticket?
    }

    private let slots = OSAllocatedUnfairLock(initialState: Slots())

    /// Replaces the old stream and its ticket. Finish outside the lock: onTermination may call this gate again.
    func subscribe(_ continuation: AsyncStream<WatchStartRequest>.Continuation) -> Int {
        let change = slots.withLock { slots in
            slots.serial += 1
            let next = Subscription(id: slots.serial, continuation: continuation)
            let previous = slots.subscription
            let answer = slots.ticket?.answer
            slots.ticket = nil
            if slots.isClosed {
                return (id: next.id, retired: Optional(next), answer: answer)
            }
            slots.subscription = next
            return (id: next.id, retired: previous, answer: answer)
        }
        change.retired?.continuation.finish()
        change.answer?.give(nil)
        return change.id
    }

    /// The old stream's delayed termination must never remove a newer subscriber or its pending request.
    func endSubscription(_ subscriptionID: Int) {
        let retired = slots.withLock { slots -> (Subscription, OneAnswer<WatchStartResult?>?)? in
            guard let subscription = slots.subscription, subscription.id == subscriptionID else { return nil }
            let answer = slots.ticket?.answer
            slots.subscription = nil
            slots.ticket = nil
            return (subscription, answer)
        }
        retired?.0.continuation.finish()
        retired?.1?.give(nil)
    }

    func admit(_ request: WatchStartRequest) -> Admission {
        slots.withLock { slots in
            guard !slots.isClosed else { return .closed }
            guard let subscription = slots.subscription else { return .noSubscriber }
            guard slots.ticket == nil else { return .busy }
            switch subscription.continuation.yield(request) {
                case .enqueued:
                    let answer = OneAnswer<WatchStartResult?>()
                    slots.ticket = Ticket(requestID: request.id, subscriptionID: subscription.id, answer: answer)
                    return .admitted(answer)
                case .dropped:
                    return .dropped
                case .terminated:
                    return .terminated
                @unknown default:
                    Logger.watchLink.error("A Start request could not be delivered to the app")
                    return .dropped
            }
        }
    }

    /// A late answer, a replaced subscription and a closed gate all refuse admission.
    func answer(requestID: Int, _ result: WatchStartResult) -> Bool {
        let answer = slots.withLock { slots -> OneAnswer<WatchStartResult?>? in
            guard let ticket = slots.ticket, ticket.requestID == requestID,
                  ticket.subscriptionID == slots.subscription?.id else { return nil }
            slots.ticket = nil
            return ticket.answer
        }
        return answer?.give(result) ?? false
    }

    func withdraw(requestID: Int) {
        slots.withLock { slots in
            if slots.ticket?.requestID == requestID { slots.ticket = nil }
        }
    }

    /// Synchronous for process termination, including streams installed after the close.
    func close() {
        let retired = slots.withLock { slots in
            slots.isClosed = true
            let retired = (continuation: slots.subscription?.continuation, answer: slots.ticket?.answer)
            slots.subscription = nil
            slots.ticket = nil
            return retired
        }
        retired.continuation?.finish()
        retired.answer?.give(nil)
    }
}
