import Foundation
import os

/// Applies each owner's syncs and ends one at a time, newest revision first, on a loop that a
/// cancelled caller does not stop: a timer that closes still has its activity removed.
actor LiveActivityCoordinator {
    static let endTimeout: Duration = .milliseconds(500)
    /// An activity iOS has not listed by then is ended and requested again on a later sync.
    static let visibilityTimeout: Duration = .seconds(10)
    static let controlTimeout: Duration = .seconds(5)

    enum Outcome {
        case shown
        /// Live Activities are off, or the user removed this one; no warning.
        case unavailable
        /// iOS has not shown it yet; the warning stays as it was.
        case deferred
        case failed
        case superseded
    }

    private struct Request {
        let attributes: WorkoutActivityAttributes
        let content: WorkoutActivityAttributes.ContentState
        let waiter: CheckedContinuation<LiveActivitySyncResult, Never>
    }

    private enum Job {
        case apply(Request)
        case end
    }

    /// Each is logged as an error once per owner.
    private enum Failure: Hashable {
        case request
        case size
        case visibility
    }

    private struct Owner {
        var acceptedRevision = Int.min
        var request: Request?
        /// The tombstone: once set, the owner never shows an activity again.
        var isEnding = false
        var endSignals: [CompletionSignal] = []
        var isDraining = false
        var activityID: String?
        var endingActivityID: String?
        var subscription: Subscription?
        var control: ControlTicket?
        var applied: WorkoutActivityAttributes.ContentState?
        var wasSeen = false
        var isGone = false
        /// A failure that a retry cannot fix; the owner stops trying.
        var isBroken = false
        /// Set while a requested activity has never been listed; true once it is overdue.
        var visibilityDeadlinePassed: (@Sendable () -> Bool)?
        var isFailing = false
        var reportedFailing = false
        var noticeSerial = 0
        var loggedFailures: Set<Failure> = []
    }

    private let transport: ActivityTransport
    private let isAppProcess: Bool
    private var owners: [UUID: Owner] = [:]
    private var controlSerial = 0
    private var subscriptionSerial = 0
    private var orphanEnds: [String: [CompletionSignal]] = [:]

    init(transport: ActivityTransport, isAppProcess: Bool = true) {
        self.transport = transport
        self.isAppProcess = isAppProcess
    }

    func sync(
        owner id: UUID,
        revision: Int,
        attributes: WorkoutActivityAttributes,
        content: WorkoutActivityAttributes.ContentState,
        clock: any Clock<Duration>
    ) async -> LiveActivityNotice? {
        await syncWithResult(owner: id, revision: revision, attributes: attributes, content: content, clock: clock).notice
    }

    func syncWithResult(
        owner id: UUID,
        revision: Int,
        attributes: WorkoutActivityAttributes,
        content: WorkoutActivityAttributes.ContentState,
        clock: any Clock<Duration>
    ) async -> LiveActivitySyncResult {
        var owner = owners[id] ?? Owner()
        guard !owner.isEnding, revision > owner.acceptedRevision else { return .init(outcome: .superseded) }

        return await withCheckedContinuation { waiter in
            owner.acceptedRevision = revision
            owner.request?.waiter.resume(returning: .init(outcome: .superseded))
            owner.request = Request(attributes: attributes, content: content, waiter: waiter)
            owners[id] = owner
            startDraining(id, clock: clock)
        }
    }

    func end(owner id: UUID, clock: any Clock<Duration>) async {
        var owner = owners[id] ?? Owner()
        if !owner.isEnding {
            owner.isEnding = true
            owner.endingActivityID = owner.activityID
            owner.subscription?.continuation.finish()
            owner.subscription = nil
            owner.control?.complete(.unavailable)
            owner.control = nil
            owner.request?.waiter.resume(returning: .init(outcome: .superseded))
            owner.request = nil
        }
        let signal = CompletionSignal()
        owner.endSignals.append(signal)
        owners[id] = owner
        startDraining(id, clock: clock)

        // A cancelled caller stops waiting too, which is no slow end.
        if await !signal.wait(timeout: Self.endTimeout, clock: clock), !Task.isCancelled {
            Logger.liveActivity.notice("Ending a live activity took over \(Self.endTimeout, privacy: .public); it ends in the background")
        }
    }

    func endOrphans() async {
        let known = Set(owners.values.compactMap(\.activityID))
        for activityID in transport.allIDs() where !known.contains(activityID) {
            await transport.end(activityID, nil, .immediate)
        }
    }

    // MARK: - The owner's loop

    private func startDraining(_ id: UUID, clock: any Clock<Duration>) {
        guard owners[id]?.isDraining == false else { return }

        owners[id]?.isDraining = true
        // The loop outlives a cancelled caller: an ending timer still has its activity removed.
        // swiftlint:disable:next no_unstructured_task
        Task {
            await drain(id, clock: clock)
        }
    }

    private func drain(_ id: UUID, clock: any Clock<Duration>) async {
        while let job = nextJob(id) {
            switch job {
                case let .apply(request):
                    let outcome = await apply(id, request, clock: clock)
                    let result: LiveActivitySyncResult.Outcome = switch outcome {
                        case .shown: .applied
                        case .unavailable: .unavailable
                        case .deferred: .deferred
                        case .failed: .failed
                        case .superseded: .superseded
                    }
                    request.waiter.resume(returning: .init(outcome: result, notice: settle(id, outcome)))
                case .end:
                    await finishEnding(id)
            }
        }
        owners[id]?.isDraining = false
    }

    private func nextJob(_ id: UUID) -> Job? {
        guard var owner = owners[id] else { return nil }

        if owner.isEnding {
            return owner.endSignals.isEmpty ? nil : .end
        }
        guard let request = owner.request else { return nil }

        owner.request = nil
        owners[id] = owner
        return .apply(request)
    }

    private func apply(_ id: UUID, _ request: Request, clock: any Clock<Duration>) async -> Outcome {
        guard let owner = owners[id], !owner.isEnding else { return .superseded }
        guard !owner.isBroken else { return .failed }
        guard !owner.isGone else { return .unavailable }
        // The run is over and its activity ended with its final content, which stays until `end(owner)`
        // removes it; iOS lists it as ended meanwhile, which is not a removal by the user.
        guard owner.applied?.phase != .finished else { return .shown }
        guard let activityID = owner.activityID else { return start(id, request, clock: clock) }

        switch transport.presence(activityID) {
            case .alive:
                owners[id]?.wasSeen = true
                owners[id]?.visibilityDeadlinePassed = nil
            case .gone:
                return markGone(id)
            case nil:
                // Once listed, missing means removed; never listed in time means it failed to show.
                if owner.wasSeen { return markGone(id) }
                if owner.visibilityDeadlinePassed?() == true { return await dropInvisible(id, activityID) }
        }
        if request.content != owner.applied {
            guard fits(id, request) else { return await breakDown(id) }

            if request.content.phase == .finished {
                await transport.end(activityID, request.content, .standard)
            } else {
                await transport.update(activityID, request.content)
            }
            guard owners[id]?.isEnding == false else { return .superseded }

            owners[id]?.applied = request.content
        }
        return owners[id]?.wasSeen == true ? .shown : .deferred
    }

    private func start(_ id: UUID, _ request: Request, clock: any Clock<Duration>) -> Outcome {
        guard transport.isEnabled(), request.content.phase != .finished else { return .unavailable }
        guard fits(id, request) else {
            owners[id]?.isBroken = true
            return .failed
        }

        let activityID: String
        do throws(ActivityRequestFailure) {
            activityID = try transport.request(request.attributes, request.content)
        } catch {
            switch error {
                case .denied:
                    return .unavailable
                case .visibility:
                    return .deferred
                case let .permanent(reason):
                    owners[id]?.isBroken = true
                    log(id, .request, "Starting a live activity failed for good: \(reason)")
                    return .failed
                case let .transient(reason):
                    log(id, .request, "Starting a live activity failed: \(reason)")
                    return .failed
            }
        }
        owners[id]?.activityID = activityID
        owners[id]?.applied = request.content
        if transport.presence(activityID) == .alive {
            owners[id]?.wasSeen = true
            return .shown
        }
        owners[id]?.visibilityDeadlinePassed = Self.deadline(after: Self.visibilityTimeout, on: clock)
        return .deferred
    }

    private func fits(_ id: UUID, _ request: Request) -> Bool {
        do {
            let size = try request.attributes.encodedSize(with: request.content)
            guard size <= WorkoutActivityAttributes.encodedSizeLimit else {
                log(id, .size, "A live activity takes \(size) bytes, over the limit")
                return false
            }
            return true
        } catch {
            log(id, .size, "Encoding a live activity failed: \(String(reflecting: error))")
            return false
        }
    }

    /// A failure no retry can fix: the activity goes, and the warning stays.
    private func breakDown(_ id: UUID) async -> Outcome {
        owners[id]?.isBroken = true
        if let activityID = owners[id]?.activityID {
            owners[id]?.activityID = nil
            await transport.end(activityID, nil, .immediate)
        }
        return .failed
    }

    private func markGone(_ id: UUID) -> Outcome {
        owners[id]?.isGone = true
        if let activityID = owners[id]?.activityID {
            owners[id]?.activityID = nil
            transport.forget(activityID)
        }
        return .unavailable
    }

    /// Ends the first request before a later sync asks for another, so two never show.
    private func dropInvisible(_ id: UUID, _ activityID: String) async -> Outcome {
        log(id, .visibility, "A live activity did not appear within \(Self.visibilityTimeout); it is requested again")
        owners[id]?.activityID = nil
        owners[id]?.applied = nil
        owners[id]?.visibilityDeadlinePassed = nil
        await transport.end(activityID, nil, .immediate)
        return .failed
    }

    private static func deadline(after duration: Duration, on clock: some Clock<Duration>) -> @Sendable () -> Bool {
        let deadline = clock.now.advanced(by: duration)
        return { clock.now >= deadline }
    }

    private func finishEnding(_ id: UUID) async {
        guard let owner = owners[id] else { return }

        owners[id]?.endSignals = []
        // Only the tombstone matters from now on; the content it showed is let go.
        owners[id]?.applied = nil
        if let activityID = owner.activityID {
            owners[id]?.activityID = nil
            await transport.end(activityID, nil, .immediate)
        }
        owner.endSignals.forEach { $0.complete() }
    }

    private func settle(_ id: UUID, _ outcome: Outcome) -> LiveActivityNotice? {
        record(id, outcome)
        guard var owner = owners[id], !owner.isEnding, owner.isFailing != owner.reportedFailing else { return nil }

        owner.noticeSerial += 1
        owner.reportedFailing = owner.isFailing
        owners[id] = owner
        return LiveActivityNotice(serial: owner.noticeSerial, isFailing: owner.isFailing)
    }

    private func record(_ id: UUID, _ outcome: Outcome) {
        switch outcome {
            case .failed:
                owners[id]?.isFailing = true
            case .shown, .unavailable:
                owners[id]?.isFailing = false
            case .deferred, .superseded:
                break
        }
    }

    /// Logs a kind of failure as an error once per owner; repeats only reach the debug log.
    private func log(_ id: UUID, _ failure: Failure, _ message: String) {
        if owners[id]?.loggedFailures.insert(failure).inserted == true {
            Logger.liveActivity.error("\(message, privacy: .public)")
        } else {
            Logger.liveActivity.debug("\(message, privacy: .public)")
        }
    }
}

// MARK: - Commands from the card

extension LiveActivityCoordinator {
    private struct Subscription {
        let id: Int
        let continuation: AsyncStream<LiveActivityControlRequest>.Continuation
    }

    /// Admission outlives the intent's wait: a timeout must not admit another command while the
    /// reducer is still applying the first. Each ticket has exactly one bounded waiter.
    private final class ControlTicket: Sendable {
        let request: LiveActivityControlRequest
        let signal = CompletionSignal()
        private let response = OSAllocatedUnfairLock<LiveActivityControlResult?>(initialState: nil)

        init(request: LiveActivityControlRequest) {
            self.request = request
        }

        var result: LiveActivityControlResult? { response.withLock { $0 } }

        func complete(_ result: LiveActivityControlResult) {
            let first = response.withLock { response in
                guard response == nil else { return false }
                response = result
                return true
            }
            if first { signal.complete() }
        }
    }

    func requests(owner id: UUID) -> AsyncStream<LiveActivityControlRequest> {
        var owner = owners[id] ?? Owner()
        guard !owner.isEnding else { return AsyncStream { $0.finish() } }

        owner.subscription?.continuation.finish()
        owner.control?.complete(.unavailable)
        owner.control = nil
        subscriptionSerial += 1
        let subscriptionID = subscriptionSerial
        let pair = AsyncStream<LiveActivityControlRequest>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pair.continuation.onTermination = { [weak self] _ in
            // Stream termination is synchronous; only actor housekeeping escapes its callback.
            // swiftlint:disable:next no_unstructured_task
            Task { await self?.subscriptionEnded(owner: id, subscriptionID: subscriptionID) }
        }
        owner.subscription = Subscription(id: subscriptionID, continuation: pair.continuation)
        owners[id] = owner
        return pair.stream
    }

    func deliver(
        activityID: String, command: LiveActivityCommand, generation: Int, clock: any Clock<Duration>
    ) async -> LiveActivityControlResult {
        // An extension must never mistake the app's live owner for an orphan in its own process.
        guard isAppProcess else { return .unavailable }
        guard !Task.isCancelled else { return .cancelled }
        guard let (id, owner) = owners.first(where: {
            $0.value.activityID == activityID || $0.value.endingActivityID == activityID
        }) else {
            return await endOrphan(activityID, clock: clock)
        }
        guard !owner.isEnding, let subscription = owner.subscription else { return .unavailable }
        guard owner.control == nil else { return .busy }

        controlSerial += 1
        let request = LiveActivityControlRequest(id: controlSerial, command: command, generation: generation)
        let ticket = ControlTicket(request: request)
        owners[id]?.control = ticket
        switch subscription.continuation.yield(request) {
            case .enqueued:
                break
            case .terminated:
                subscriptionEnded(owner: id, subscriptionID: subscription.id)
                return .unavailable
            case .dropped:
                Logger.liveActivity.error("An admitted live activity command did not fit its empty stream buffer")
                subscriptionEnded(owner: id, subscriptionID: subscription.id)
                return .unavailable
            @unknown default:
                Logger.liveActivity.error("An admitted live activity command could not be delivered")
                subscriptionEnded(owner: id, subscriptionID: subscription.id)
                return .unavailable
        }
        _ = await ticket.signal.wait(timeout: Self.controlTimeout, clock: clock)
        if let result = ticket.result { return result }
        if Task.isCancelled { return .cancelled }

        Logger.liveActivity.notice("A live activity command took over \(Self.controlTimeout, privacy: .public); the timer still owns it")
        return .timedOut
    }

    func requestHandled(owner id: UUID, requestID: Int, result: LiveActivityControlResult) {
        guard let ticket = owners[id]?.control, ticket.request.id == requestID else { return }

        owners[id]?.control = nil
        ticket.complete(result)
    }

    private func subscriptionEnded(owner id: UUID, subscriptionID: Int) {
        guard owners[id]?.subscription?.id == subscriptionID else { return }

        owners[id]?.subscription?.continuation.finish()
        owners[id]?.subscription = nil
        owners[id]?.control?.complete(.unavailable)
        owners[id]?.control = nil
    }

    private func endOrphan(_ activityID: String, clock: any Clock<Duration>) async -> LiveActivityControlResult {
        guard transport.allIDs().contains(activityID) else { return .unavailable }

        let signal = CompletionSignal()
        let isFirst = orphanEnds[activityID] == nil
        orphanEnds[activityID, default: []].append(signal)
        if isFirst {
            // Removal outlives a cancelled or timed-out intent; each caller has its own bounded wait.
            // swiftlint:disable:next no_unstructured_task
            Task {
                await transport.end(activityID, nil, .immediate)
                let signals = orphanEnds.removeValue(forKey: activityID) ?? []
                signals.forEach { $0.complete() }
            }
        }
        let completed = await signal.wait(timeout: Self.endTimeout, clock: clock)
        // Keep the removal registered, but release a caller that no longer waits for it.
        orphanEnds[activityID]?.removeAll { $0 === signal }
        if Task.isCancelled { return .cancelled }
        if !completed {
            Logger.liveActivity.notice("Ending an orphan activity took over \(Self.endTimeout, privacy: .public); removal continues")
        }
        return .orphanEnded
    }
}
