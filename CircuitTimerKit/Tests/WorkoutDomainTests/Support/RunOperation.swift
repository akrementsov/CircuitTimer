@testable import WorkoutDomain

import Foundation

/// A public `WorkoutRun` operation as a value, so tables and property tests can apply any of them.
enum RunOperation: Sendable, CustomStringConvertible {
    case tick
    case start
    case pause
    case resume
    case skip
    case rebase(Duration)

    static let allExceptStart: [RunOperation] = [.tick, .pause, .resume, .skip, .rebase(.seconds(7))]
    static let all: [RunOperation] = [.start] + allExceptStart

    var description: String {
        switch self {
            case .tick:
                "tick"
            case .start:
                "start"
            case .pause:
                "pause"
            case .resume:
                "resume"
            case .skip:
                "skip"
            case let .rebase(kept):
                "rebase(\(kept))"
        }
    }

    func apply(to run: inout WorkoutRun, at now: Date) {
        switch self {
            case .tick:
                run.tick(at: now)
            case .start:
                run.start(at: now)
            case .pause:
                run.pause(at: now)
            case .resume:
                run.resume(at: now)
            case .skip:
                run.skipToNextStage(at: now)
            case let .rebase(kept):
                run.rebase(at: now, keepingTotalElapsed: kept)
        }
    }

    func applied(to run: WorkoutRun, at now: Date) -> WorkoutRun {
        var run = run
        apply(to: &run, at: now)
        return run
    }

    static func random(total: Duration, using generator: inout SeededGenerator) -> RunOperation {
        switch Int.random(in: 0..<20, using: &generator) {
            case 0..<6:
                .tick
            case 6..<9:
                .start
            case 9..<12:
                .pause
            case 12..<15:
                .resume
            case 15..<18:
                .skip
            case 18:
                .rebase(.seconds(Int64.max))
            default:
                .rebase(.milliseconds(Int64.random(in: -10_000...(total.inMilliseconds + 10_000), using: &generator)))
        }
    }
}
