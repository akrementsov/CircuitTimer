import Foundation
import os
import WorkoutActivity

/// The timer's answer to a command: its result and the run as it published it, `nil` when it publishes none.
struct CommandAnswer: Sendable {
    let result: LiveActivityControlResult
    let publication: WatchRunPublication?
}

/// The commands handed to timers and not answered yet, under one lock with the gate termination closes. Closing, the
/// check and the hand-over to a timer's stream happen together, so no command reaches a timer after `close()`.
///
/// Every ticket here was handed to its timer, which may have applied it: a ticket that ends without the timer's
/// answer gets `timedOut`, never «not applied».
final class CommandGate: Sendable {
    enum Admission {
        case admitted(OneAnswer<CommandAnswer?>)
        case closed
        case dropped
        case terminated
    }

    private struct Ticket {
        let owner: UUID
        let subscriptionID: Int
        let answer: OneAnswer<CommandAnswer?>
    }

    private struct Tickets {
        var isClosed = false
        var issued: [Int: Ticket] = [:]
    }

    private static let unknown = CommandAnswer(result: .timedOut, publication: nil)

    private let tickets = OSAllocatedUnfairLock(initialState: Tickets())

    /// Hands the command to the timer's stream, unless the gate is closed; only a command the stream took gets a
    /// ticket.
    func admit(
        _ request: WatchControlRequest,
        owner: UUID,
        subscriptionID: Int,
        into continuation: AsyncStream<WatchControlRequest>.Continuation
    ) -> Admission {
        tickets.withLock { tickets in
            guard !tickets.isClosed else { return .closed }
            switch continuation.yield(request) {
                case .enqueued:
                    let answer = OneAnswer<CommandAnswer?>()
                    tickets.issued[request.id] = Ticket(owner: owner, subscriptionID: subscriptionID, answer: answer)
                    return .admitted(answer)
                case .dropped:
                    return .dropped
                case .terminated:
                    return .terminated
                @unknown default:
                    Logger.watchLink.error("A command could not be delivered to the timer")
                    return .dropped
            }
        }
    }

    /// Gives the timer's answer to its waiting ticket; `false` when no ticket of this owner waits for it any more.
    func answer(requestID: Int, owner: UUID, _ answer: CommandAnswer) -> Bool {
        let ticket = tickets.withLock { tickets -> Ticket? in
            guard let ticket = tickets.issued[requestID], ticket.owner == owner else { return nil }
            tickets.issued[requestID] = nil
            return ticket
        }
        return ticket?.answer.give(answer) ?? false
    }

    /// Forgets a ticket whose wait gave up.
    func withdraw(requestID: Int) {
        _ = tickets.withLock { $0.issued.removeValue(forKey: requestID) }
    }

    /// The subscription's commands may have been applied before it ended: they are answered as unknown.
    func endSubscription(owner: UUID, subscriptionID: Int) {
        let ended = tickets.withLock { tickets in
            let ended = tickets.issued.filter { $0.value.owner == owner && $0.value.subscriptionID == subscriptionID }
            for id in ended.keys {
                tickets.issued[id] = nil
            }
            return Array(ended.values)
        }
        for ticket in ended {
            ticket.answer.give(Self.unknown)
        }
    }

    /// Synchronous, for termination: later commands are refused, and every handed-over one is answered as unknown.
    func close() {
        let waiting = tickets.withLock { tickets in
            tickets.isClosed = true
            defer { tickets.issued = [:] }
            return Array(tickets.issued.values)
        }
        for ticket in waiting {
            ticket.answer.give(Self.unknown)
        }
    }
}
