import ComposableArchitecture

/// Advances the monotonic reading through a TestClock without waking effects, like process suspension.
struct SuspendingClock: Clock {
    let base: TestClock<Duration>

    var now: TestClock<Duration>.Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    func sleep(until _: TestClock<Duration>.Instant, tolerance _: Duration?) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
        try Task.checkCancellation()
    }
}
