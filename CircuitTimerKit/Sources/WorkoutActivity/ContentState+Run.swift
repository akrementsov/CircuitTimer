import Foundation
import WorkoutDomain

extension WorkoutActivityAttributes.ContentState {
    /// The state of `run` settled at `now`. The run never counts while it waits for the start
    /// countdown or the resume countdown, so those read as `getReady` and `paused`.
    public init(run: WorkoutRun, at now: Date) {
        var run = run
        run.tick(at: now)
        let snapshot = run.snapshot(at: now)
        self.init(phase: Self.phase(of: snapshot, outlook: run.outlook(at: now)))
    }

    private static func phase(of snapshot: WorkoutRun.Snapshot, outlook: WorkoutRun.Outlook?) -> WorkoutActivityAttributes.Phase {
        switch snapshot.status {
            case .idle:
                guard let stage = snapshot.currentStage else { return .finished }

                return .getReady(first: held(stage, remaining: stage.duration))
            case .running:
                guard let stage = snapshot.currentStage, stage.kind != .pause, let outlook else {
                    return .awaitingUser(next: snapshot.nextStage.map { held($0, remaining: $0.duration) })
                }

                return .running(
                    WorkoutActivityAttributes.Running(
                        stage: WorkoutActivityAttributes.Stage(stage),
                        stageStart: outlook.stageStart,
                        stageEnd: outlook.stageEnd,
                        next: next(after: snapshot.nextStage, end: outlook.nextStageEnd)
                    )
                )
            case .paused:
                guard let stage = snapshot.currentStage else { return .finished }

                return .paused(held(stage, remaining: snapshot.stageRemaining))
            case .awaitingUser:
                return .awaitingUser(next: snapshot.nextStage.map { held($0, remaining: $0.duration) })
            case .finished:
                return .finished
        }
    }

    private static func next(after stage: ScheduledStage?, end: Date?) -> WorkoutActivityAttributes.Next {
        guard let stage else { return .finish }
        guard stage.kind != .pause, let end else { return .manualPause }

        return .stage(WorkoutActivityAttributes.Stage(stage), end: end)
    }

    private static func held(_ stage: ScheduledStage, remaining: Duration) -> WorkoutActivityAttributes.HeldStage {
        WorkoutActivityAttributes.HeldStage(
            stage: WorkoutActivityAttributes.Stage(stage),
            remainingMilliseconds: remaining.inMilliseconds
        )
    }
}

extension WorkoutActivityAttributes.Stage {
    init(_ stage: ScheduledStage) {
        let kind: Kind = switch stage.kind {
            case .work:
                .work
            case .rest:
                .rest
            case .pause:
                .pause
        }
        self.init(kind: kind, name: stage.name)
    }
}
