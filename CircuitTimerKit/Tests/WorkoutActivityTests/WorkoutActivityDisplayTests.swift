@testable import WorkoutActivity

import Foundation
import Testing

@Suite
struct WorkoutActivityDisplayTests {
    typealias Display = WorkoutActivityDisplay

    private static func display(_ phase: Attributes.Phase, isStale: Bool = false, name: String = "Morning") -> Display {
        Display(attributes: Attributes(workoutName: name), content: Content(phase: phase), isStale: isStale)
    }

    private static func running(next: Attributes.Next, start: Date = origin, end: Date = moment(10)) -> Attributes.Phase {
        .running(Attributes.Running(stage: .work(), stageStart: start, stageEnd: end, next: next))
    }

    @Test
    func test_init_getReady_showsTheFirstStageInFullNext() {
        let display = Self.display(.getReady(first: Attributes.HeldStage(stage: .work(), remainingMilliseconds: 10_000)))

        #expect(display.tone == .rest)
        #expect(display.headline == .getReady)
        #expect(display.clock == Display.Clock.none)
        #expect(display.next == Display.Next(label: .named("Squats"), tone: .work, clock: .fixed(.seconds(10))))
    }

    @Test
    func test_init_running_countsTheStageAndTheNextFromItsEnd() {
        let display = Self.display(Self.running(next: .stage(.rest(), end: moment(15))))

        #expect(display.tone == .work)
        #expect(display.headline == .named("Squats"))
        #expect(display.clock == .counting(origin...moment(10)))
        #expect(display.next == Display.Next(label: .rest, tone: .rest, clock: .counting(moment(10)...moment(15))))
    }

    @Test(arguments: [
        (Attributes.Next.manualPause, Display.Label.pause),
        (.finish, .finished),
    ])
    func test_init_running_withoutATimedNextStage_namesItWithoutAClock(next: Attributes.Next, label: Display.Label) {
        let display = Self.display(Self.running(next: next))

        #expect(display.next == Display.Next(label: label, tone: .dark, clock: Display.Clock.none))
    }

    @Test
    func test_init_paused_showsTheGlyphAndTheIslandTheTimeLeft() {
        let display = Self.display(.paused(Attributes.HeldStage(stage: .work(), remainingMilliseconds: 23_000)))

        #expect(display.tone == .dark)
        #expect(display.headline == .pause)
        #expect(display.clock == .pauseGlyph)
        #expect(display.islandClock == .fixed(.seconds(23)))
        #expect(display.next == Display.Next(label: .named("Squats"), tone: .work, clock: .fixed(.seconds(23))))
    }

    @Test
    func test_init_awaitingUser_showsTheGlyphEverywhere() {
        let upcoming = Self.display(.awaitingUser(next: Attributes.HeldStage(stage: .work("Lunges"), remainingMilliseconds: 10_000)))
        let last = Self.display(.awaitingUser(next: nil))

        #expect(upcoming.tone == .dark)
        #expect(upcoming.headline == .pause)
        #expect(upcoming.clock == .pauseGlyph)
        #expect(upcoming.islandClock == .pauseGlyph)
        #expect(upcoming.next == Display.Next(label: .named("Lunges"), tone: .work, clock: .fixed(.seconds(10))))
        #expect(last.next == Display.Next(label: .finished, tone: .dark, clock: Display.Clock.none))
    }

    @Test
    func test_init_finished_showsTheFinishGlyphWithNothingNext() {
        let display = Self.display(.finished)

        #expect(display.tone == .dark)
        #expect(display.headline == .finished)
        #expect(display.clock == .finishedGlyph)
        #expect(display.next == nil)
    }

    @Test
    func test_init_staleRunning_movesOnToTheNextStageAndAsksToOpenTheApp() {
        let display = Self.display(Self.running(next: .stage(.rest(), end: moment(15))), isStale: true)

        #expect(display.tone == .rest)
        #expect(display.headline == .rest)
        #expect(display.clock == .counting(moment(10)...moment(15)))
        #expect(display.next == Display.Next(label: .openApp, tone: .dark, clock: Display.Clock.none))
    }

    @Test
    func test_init_staleRunning_withoutATimedNextStage_showsWhatStoppedIt() {
        let pause = Self.display(Self.running(next: .manualPause), isStale: true)
        let finish = Self.display(Self.running(next: .finish), isStale: true)

        #expect(pause.tone == .dark)
        #expect(pause.headline == .pause)
        #expect(pause.clock == .pauseGlyph)
        #expect(pause.next == Display.Next(label: .openApp, tone: .dark, clock: Display.Clock.none))
        #expect(finish.headline == .finished)
        #expect(finish.clock == .finishedGlyph)
        #expect(finish.next == nil)
    }

    @Test(arguments: [
        ("Morning", Display.Title.named("Morning")),
        ("  Morning ", .named("  Morning ")),
        ("", .untitled),
        ("   ", .untitled),
        ("\n\t", .untitled),
    ])
    func test_init_workoutName_blankReadsAsUntitled(name: String, expected: Display.Title) {
        #expect(Self.display(.finished, name: name).title == expected)
    }

    @Test(arguments: [
        (Attributes.Stage(kind: .work, name: "  Squats "), Display.Label.named("Squats")),
        (Attributes.Stage(kind: .work, name: ""), .work),
        (Attributes.Stage(kind: .rest, name: "  "), .rest),
        (Attributes.Stage(kind: .pause, name: nil), .pause),
    ])
    func test_init_stageName_blankReadsAsItsIntensity(stage: Attributes.Stage, expected: Display.Label) {
        let display = Self.display(.running(Attributes.Running(stage: stage, stageStart: origin, stageEnd: moment(10), next: .finish)))

        #expect(display.headline == expected)
    }

    @Test
    func test_init_crossedDates_neverInvertARange() {
        let running = Self.display(Self.running(next: .stage(.rest(), end: moment(15)), start: moment(10.001), end: moment(10)))
        let stale = Self.display(Self.running(next: .stage(.rest(), end: moment(9.999))), isStale: true)

        #expect(running.clock == .counting(moment(10)...moment(10)))
        #expect(stale.clock == .counting(moment(9.999)...moment(9.999)))
    }
}
