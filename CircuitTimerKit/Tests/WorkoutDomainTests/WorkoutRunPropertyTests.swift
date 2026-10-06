@testable import WorkoutDomain

import Foundation
import Testing

/// Seeded random runs checked against the invariants in docs/timer-engine.md.
@Suite
struct WorkoutRunPropertyTests {
    @Test
    func test_randomOperationSequences_keepInvariants() {
        var generator = SeededGenerator(seed: 0x5EED)
        for iteration in 0..<300 {
            var run = makeRun(.random(using: &generator, rounds: 0...3))
            var now = origin
            for step in 0..<50 {
                now = nextMoment(after: now, using: &generator)
                let operation = RunOperation.random(total: run.schedule.totalDuration, using: &generator)
                let before = run
                operation.apply(to: &run, at: now)

                let context: Comment = "iteration \(iteration), step \(step), \(operation) → \(RunState(run))"
                expectInvariants(run, at: now, context)
                #expect(run.position >= before.position, "position never moves back; \(context)")
                expectTickIsProjected(run, at: now.addingTimeInterval(Double.random(in: 0...5, using: &generator)), context)
                #expect(RunOperation.tick.applied(to: run, at: now) == run, "a second tick at the same moment changes nothing; \(context)")
            }
        }
    }

    @Test
    func test_manyOneSecondTicks_matchSingleTickWithinOneMillisecond() {
        let longStages = (1...10).map { makeStage($0, .seconds(5_999)) }
        var ticked = RunOperation.start.applied(to: makeRun(Workout(id: UUID(fixture: 0), warmUp: longStages)), at: origin)
        let untouched = ticked
        for second in 1...50_000 {
            ticked.tick(at: moment(Double(second)))
        }

        let single = RunOperation.tick.applied(to: untouched, at: moment(50_000))
        let difference = ticked.position > single.position ? ticked.position - single.position : single.position - ticked.position
        #expect(difference <= .milliseconds(1), "positions differ by \(difference)")
    }

    @Test
    func test_manyIrregularTicks_stayWithinAboutOneMillisecondOfRealTime() {
        var generator = SeededGenerator(seed: 0xD21F7)
        let longStages = (1...10).map { makeStage($0, .seconds(5_999)) }
        var ticked = RunOperation.start.applied(to: makeRun(Workout(id: UUID(fixture: 0), warmUp: longStages)), at: origin)
        let untouched = ticked
        var now = origin
        for _ in 0..<50_000 {
            now = now.addingTimeInterval(Double.random(in: 0.001...1.5, using: &generator))
            ticked.tick(at: now)
        }

        let real = now.timeIntervalSince(origin)
        let afterManyTicks = Double(ticked.position.inMilliseconds) / 1_000
        let afterOneTick = Double(RunOperation.tick.applied(to: untouched, at: now).position.inMilliseconds) / 1_000
        #expect(abs(real - afterManyTicks) <= 0.001_01, "50 000 ticks trail real time by \(real - afterManyTicks) s")
        #expect(abs(afterOneTick - afterManyTicks) <= 0.001_01)
    }

    private func nextMoment(after now: Date, using generator: inout SeededGenerator) -> Date {
        switch Int.random(in: 0..<100, using: &generator) {
            case 0..<70:
                now.addingTimeInterval(Double.random(in: 0...30, using: &generator))
            case 70..<85:
                now.addingTimeInterval(Double.random(in: 0...0.002, using: &generator))
            case 85..<93:
                now.addingTimeInterval(-Double.random(in: 0...10, using: &generator))
            case 93..<98:
                now.addingTimeInterval(3_600)
            case 98:
                .distantFuture
            default:
                .distantPast
        }
    }

    private func expectInvariants(_ run: WorkoutRun, at now: Date, _ context: Comment) {
        let stages = run.schedule.stages
        // I1
        #expect((0...stages.count).contains(run.cursor), context)
        #expect((run.cursor == stages.count) == (run.phase == .finished), context)
        // I2
        if run.phase == .idle {
            #expect(!stages.isEmpty && run.cursor == 0 && run.position == .zero, context)
        }
        // I3
        if run.phase == .finished {
            #expect(run.position == run.schedule.totalDuration, context)
        }
        // I4, I5
        if stages.indices.contains(run.cursor), run.phase != .idle {
            let stage = stages[run.cursor]
            #expect(stage.start <= run.position && run.position <= stage.end, context)
            #expect((stage.kind == .pause) == (run.phase == .awaitingUser), context)
            if run.phase == .paused || run.phase.isRunning {
                #expect(run.position < stage.end, context)
            }
        }
        // I6
        #expect(run.position.isWholeMilliseconds, context)
        // I9
        if case let .running(since) = run.phase {
            #expect(since <= now, context)
        }
    }

    /// I7: a snapshot equals the projection of the committed state at the same moment.
    private func expectTickIsProjected(_ run: WorkoutRun, at moment: Date, _ context: Comment) {
        #expect(run.snapshot(at: moment) == RunOperation.tick.applied(to: run, at: moment).projection(), context)
    }
}

private extension WorkoutRun.Phase {
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}
