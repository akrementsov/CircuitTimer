@testable import BackgroundNotifications

import Foundation
import os

final class NotificationFake: Sendable {
    private struct State {
        var added: [String] = []
        var pending: Set<String> = []
        var delivered: Set<String> = []
        var removed: [String] = []
        var removedDelivered: [String] = []
        var removeDeliveredCalls: [[String]] = []
        var access = NotificationAccess.authorized
        var recordsPending = true
        var holdsAdd = false
        var holdsPending = false
        var holdsDelivered = false
        var holdsSettings = false
        var pendingReads = 0
        var deliveredReads = 0
        var settingsReads = 0
        var addFailure: NotificationFailure?
        var beforeAdd: (@Sendable () -> Void)?
        var addCallbacks: [String: @Sendable (Result<Void, NotificationFailure>) -> Void] = [:]
        var pendingCallbacks: [@Sendable ([String]) -> Void] = []
        var deliveredCallbacks: [@Sendable ([String]) -> Void] = []
        var observers: [AsyncStream<Void>.Continuation] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var added: [String] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }
    var removedDelivered: [String] { state.withLock { $0.removedDelivered } }
    var removeDeliveredCalls: [[String]] { state.withLock { $0.removeDeliveredCalls } }
    var pendingReads: Int { state.withLock { $0.pendingReads } }
    var deliveredReads: Int { state.withLock { $0.deliveredReads } }
    var settingsReads: Int { state.withLock { $0.settingsReads } }
    var access: NotificationAccess {
        get { state.withLock { $0.access } }
        set { state.withLock { $0.access = newValue } }
    }
    var holdsSettings: Bool {
        get { state.withLock { $0.holdsSettings } }
        set { state.withLock { $0.holdsSettings = newValue } }
    }
    var addFailure: NotificationFailure? {
        get { state.withLock { $0.addFailure } }
        set { state.withLock { $0.addFailure = newValue } }
    }
    var recordsPending: Bool {
        get { state.withLock { $0.recordsPending } }
        set { state.withLock { $0.recordsPending = newValue } }
    }
    var holdsAdd: Bool {
        get { state.withLock { $0.holdsAdd } }
        set { state.withLock { $0.holdsAdd = newValue } }
    }
    var holdsPending: Bool {
        get { state.withLock { $0.holdsPending } }
        set { state.withLock { $0.holdsPending = newValue } }
    }
    var holdsDelivered: Bool {
        get { state.withLock { $0.holdsDelivered } }
        set { state.withLock { $0.holdsDelivered = newValue } }
    }
    var pendingIdentifiers: Set<String> {
        get { state.withLock { $0.pending } }
        set { state.withLock { $0.pending = newValue } }
    }
    var deliveredIdentifiers: Set<String> {
        get { state.withLock { $0.delivered } }
        set { state.withLock { $0.delivered = newValue } }
    }
    var beforeAdd: (@Sendable () -> Void)? {
        get { state.withLock { $0.beforeAdd } }
        set { state.withLock { $0.beforeAdd = newValue } }
    }
    var transport: NotificationTransport {
        NotificationTransport(
            settings: { [self] callback in
                let value = state.withLock { state -> NotificationAccess? in
                    state.settingsReads += 1
                    notify(state)
                    return state.holdsSettings ? nil : state.access
                }
                if let value { callback(value) }
            },
            authorize: { $0(.success(())) },
            add: { [self] id, _, _, _, callback in
                beforeAdd?()
                let (held, failure) = state.withLock { state in
                    state.added.append(id)
                    if state.recordsPending && state.addFailure == nil { state.pending.insert(id) }
                    if state.holdsAdd { state.addCallbacks[id] = callback }
                    notify(state)
                    return (state.holdsAdd, state.addFailure)
                }
                if !held { callback(failure.map { .failure($0) } ?? .success(())) }
            },
            pending: { [self] callback in
                let value = state.withLock { state -> [String]? in
                    state.pendingReads += 1
                    if state.holdsPending { state.pendingCallbacks.append(callback) }
                    notify(state)
                    return state.holdsPending ? nil : Array(state.pending)
                }
                if let value { callback(value) }
            },
            delivered: { [self] callback in
                let value = state.withLock { state -> [String]? in
                    state.deliveredReads += 1
                    if state.holdsDelivered { state.deliveredCallbacks.append(callback) }
                    notify(state)
                    return state.holdsDelivered ? nil : Array(state.delivered)
                }
                if let value { callback(value) }
            },
            removePending: { [self] ids in state.withLock { $0.removed += ids; $0.pending.subtract(ids) } },
            removeDelivered: { [self] ids in
                state.withLock {
                    $0.removeDeliveredCalls.append(ids)
                    $0.removedDelivered += ids
                    $0.delivered.subtract(ids)
                }
            }
        )
    }
    func completeAdd(_ id: String, result: Result<Void, NotificationFailure> = .success(())) {
        let callback = state.withLock { $0.addCallbacks.removeValue(forKey: id) }
        callback?(result)
    }
    func completeAdds() {
        let ids = state.withLock { Array($0.addCallbacks.keys) }
        for id in ids { completeAdd(id) }
    }
    func completePending() {
        let (callbacks, ids) = state.withLock { state in
            let callbacks = state.pendingCallbacks
            state.pendingCallbacks = []
            state.holdsPending = false
            return (callbacks, Array(state.pending))
        }
        for callback in callbacks { callback(ids) }
    }
    func completeDelivered() {
        let (callbacks, ids) = state.withLock { state in
            let callbacks = state.deliveredCallbacks
            state.deliveredCallbacks = []
            state.holdsDelivered = false
            return (callbacks, Array(state.delivered))
        }
        for callback in callbacks { callback(ids) }
    }
    func waitForAdd(count: Int = 1) async { await wait { $0.added.count >= count } }
    func waitForPending(count: Int = 1) async { await wait { $0.pendingReads >= count } }
    func waitForDelivered(count: Int = 1) async { await wait { $0.deliveredReads >= count } }
    func waitForSettings(count: Int) async { await wait { $0.settingsReads >= count } }

    private func notify(_ state: State) {
        for observer in state.observers { observer.yield(()) }
    }

    private func wait(until ready: @escaping @Sendable (State) -> Bool) async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.observers.append(pair.continuation)
            pair.continuation.yield(())
        }
        defer { pair.continuation.finish() }
        for await _ in pair.stream {
            let isReady = state.withLock { ready($0) }
            if isReady { return }
        }
    }
}
