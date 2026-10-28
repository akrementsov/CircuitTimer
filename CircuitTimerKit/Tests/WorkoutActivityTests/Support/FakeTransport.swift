@testable import WorkoutActivity

import Dependencies
import Foundation

/// An `ActivityTransport` that records every call and lets a test decide what iOS answers.
final class FakeTransport: Sendable {
    enum Call: Equatable, Sendable {
        case request(Content)
        case update(String, Content)
        case end(String, Content?, ActivityDismissal)
        case forget(String)
    }

    let calls = LockIsolated<[Call]>([])
    /// The attributes of each request, in order.
    let requestedAttributes = LockIsolated<[Attributes]>([])
    let isEnabled = LockIsolated(true)
    /// Consumed one per request before any succeeds.
    let requestFailures = LockIsolated<[ActivityRequestFailure]>([])
    /// Whether a requested activity is listed at once.
    let listsOnRequest = LockIsolated(true)
    let presence = LockIsolated<[String: ActivityPresence]>([:])
    /// Holds the next update or end until the test opens it.
    let updateGate = LockIsolated<Gate?>(nil)
    let endGate = LockIsolated<Gate?>(nil)
    private let nextID = LockIsolated(0)

    var transport: ActivityTransport {
        ActivityTransport(
            isEnabled: { self.isEnabled.value },
            request: { attributes, state throws(ActivityRequestFailure) in
                self.calls.withValue { $0.append(.request(state)) }
                self.requestedAttributes.withValue { $0.append(attributes) }
                let failure = self.requestFailures.withValue { $0.isEmpty ? nil : $0.removeFirst() }
                if let failure { throw failure }

                let id = self.nextID.withValue {
                    $0 += 1
                    return "activity-\($0)"
                }
                if self.listsOnRequest.value {
                    self.presence.withValue { $0[id] = .alive }
                }
                return id
            },
            update: { id, state in
                await self.updateGate.value?.pass()
                self.calls.withValue { $0.append(.update(id, state)) }
            },
            end: { id, state, dismissal in
                await self.endGate.value?.pass()
                self.calls.withValue { $0.append(.end(id, state, dismissal)) }
            },
            endEvery: { between in await between() },
            forget: { id in
                self.calls.withValue { $0.append(.forget(id)) }
            },
            presence: { id in self.presence.value[id] },
            allIDs: { self.presence.value.keys.sorted() }
        )
    }
}

/// A one-shot barrier: callers of `pass()` wait until `open()`, and `entered` reports each arrival.
final class Gate: Sendable {
    private let state = LockIsolated<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    private let arrivals = AsyncStream<Void>.makeStream()

    /// Iterate it from one task only.
    var entered: AsyncStream<Void> {
        arrivals.stream
    }

    func pass() async {
        arrivals.continuation.yield()
        await withCheckedContinuation { continuation in
            let isOpen = state.withValue { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withValue { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

extension AsyncStream {
    /// Waits for the next element.
    func next() async {
        var iterator = makeAsyncIterator()
        _ = await iterator.next()
    }
}
