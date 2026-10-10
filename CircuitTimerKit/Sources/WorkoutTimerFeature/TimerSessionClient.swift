import ComposableArchitecture
import Foundation
import UIKit

/// One record per timer screen: its keep-awake vote and whether it has closed.
@DependencyClient
public struct TimerSessionClient: Sendable {
    /// Ignored when `revision` is not newer than the last request applied for `owner`, or once the session has ended.
    public var requestAwake: @Sendable (_ owner: UUID, _ awake: Bool, _ revision: Int) async -> Void
    /// Drops the session's vote and rejects anything it sends later.
    public var end: @Sendable (_ owner: UUID) async -> Void
    /// The default is what the unimplemented `testValue` returns after reporting the call.
    public var isEnded: @Sendable (_ owner: UUID) async -> Bool = { _ in false }
}

extension TimerSessionClient: DependencyKey {
    public static let liveValue: Self = {
        let sessions = TimerSessions { isAwake in
            UIApplication.shared.isIdleTimerDisabled = isAwake
        }
        return Self(
            requestAwake: { owner, awake, revision in
                await sessions.requestAwake(owner: owner, awake: awake, revision: revision)
            },
            end: { owner in
                await sessions.end(owner: owner)
            },
            isEnded: { owner in
                await sessions.isEnded(owner: owner)
            }
        )
    }()
    public static let previewValue = Self(
        requestAwake: { _, _, _ in },
        end: { _ in },
        isEnded: { _ in false }
    )
    /// Declared explicitly so each endpoint a test forgets to override reports itself as unimplemented,
    /// instead of any access failing the test while preview data is returned.
    public static let testValue = Self()
}

extension DependencyValues {
    public var timerSession: TimerSessionClient {
        get { self[TimerSessionClient.self] }
        set { self[TimerSessionClient.self] = newValue }
    }
}

/// Keeps the screen awake while any open timer session votes for it.
///
/// An ended session keeps a 16-byte tombstone for the life of the process, so a request that arrives
/// after its screen closed cannot bring a vote back.
@MainActor
final class TimerSessions {
    private let apply: @MainActor (Bool) -> Void
    private var votes: [UUID: (revision: Int, awake: Bool)] = [:]
    private var ended: Set<UUID> = []

    nonisolated init(apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
    }

    func requestAwake(owner: UUID, awake: Bool, revision: Int) {
        guard !ended.contains(owner) else { return }
        if let vote = votes[owner], vote.revision >= revision { return }

        votes[owner] = (revision, awake)
        applyVotes()
    }

    func end(owner: UUID) {
        votes[owner] = nil
        ended.insert(owner)
        applyVotes()
    }

    func isEnded(owner: UUID) -> Bool {
        ended.contains(owner)
    }

    private func applyVotes() {
        apply(votes.values.contains { $0.awake })
    }
}
