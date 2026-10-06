import Foundation

extension WorkoutRun {
    /// What the UI shows at a given moment. Taking a snapshot never commits progress;
    /// call `tick(at:)` for that.
    public struct Snapshot: Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case idle
            case running
            case paused
            case awaitingUser
            case finished
        }

        public let status: Status
        public let currentStage: ScheduledStage?
        public let nextStage: ScheduledStage?
        public let stageElapsed: Duration
        public let stageRemaining: Duration
        public let totalElapsed: Duration
        public let totalRemaining: Duration
        /// When the current stage ends if nothing interrupts it; only set while running.
        public let currentStageEndDate: Date?
    }

    func projection() -> Snapshot {
        let total = schedule.totalDuration
        guard phase != .finished, schedule.stages.indices.contains(cursor) else {
            return Snapshot(
                status: .finished,
                currentStage: nil,
                nextStage: nil,
                stageElapsed: .zero,
                stageRemaining: .zero,
                totalElapsed: total,
                totalRemaining: .zero,
                currentStageEndDate: nil
            )
        }

        let stage = schedule.stages[cursor]
        var endDate: Date?
        if case let .running(since) = phase {
            endDate = since.adding(stage.end - position)
        }
        return Snapshot(
            status: phase.status,
            currentStage: stage,
            nextStage: schedule.next(after: stage),
            stageElapsed: position - stage.start,
            stageRemaining: stage.end - position,
            totalElapsed: position,
            totalRemaining: total - position,
            currentStageEndDate: endDate
        )
    }
}

private extension WorkoutRun.Phase {
    var status: WorkoutRun.Snapshot.Status {
        switch self {
            case .idle:
                .idle
            case .running:
                .running
            case .paused:
                .paused
            case .awaitingUser:
                .awaitingUser
            case .finished:
                .finished
        }
    }
}
