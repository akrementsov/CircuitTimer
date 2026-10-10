@testable import WorkoutDomain
@testable import WorkoutTimerFeature

import Foundation
import Testing

/// Expected texts come from the module's catalog, so the tests pass in any simulator language.
@MainActor
@Suite
struct TimerDisplayTests {
    private typealias State = WorkoutTimerFeature.State
    private typealias Card = WorkoutTimerFeature.State.CurrentCard

    enum CardRow: CaseIterable, Sendable {
        case runningWork
        case runningRest
        case runningPauseStage
        case idle
        case paused
        case awaitingUser
        case finished
        case startCountdown
        case resumeCountdown
    }

    private static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    private static func spoken(_ name: String, _ value: String) -> String {
        text("timer.current.spoken \(name) \(value)")
    }

    private static func spokenSeconds(_ seconds: Int64) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    private static func snapshot(
        _ status: WorkoutRun.Snapshot.Status,
        stage: ScheduledStage? = nil,
        totalElapsed: Duration = .zero,
        totalRemaining: Duration = .zero
    ) -> WorkoutRun.Snapshot {
        WorkoutRun.Snapshot(
            status: status,
            currentStage: stage,
            nextStage: nil,
            stageElapsed: .zero,
            stageRemaining: .zero,
            totalElapsed: totalElapsed,
            totalRemaining: totalRemaining,
            currentStageEndDate: nil
        )
    }

    @Test(arguments: CardRow.allCases)
    func test_currentCard_eachPhase_showsItsCard(row: CardRow) {
        let pause = Self.text("timer.stage.pause")
        let getReady = Self.text("timer.stage.getReady")
        let state: State
        let expected: Card
        switch row {
            case .runningWork:
                state = .fixture(.running, elapsed: 2.6)
                expected = Card(
                    tone: .work,
                    content: .clock("00:08"),
                    name: "Stage 1",
                    spokenValue: Self.spoken("Stage 1", Self.spokenSeconds(8))
                )
            case .runningRest:
                state = .fixture(.running, elapsed: 11)
                expected = Card(
                    tone: .rest,
                    content: .clock("00:04"),
                    name: "Stage 2",
                    spokenValue: Self.spoken("Stage 2", Self.spokenSeconds(4))
                )
            case .runningPauseStage:
                var running = State.fixture(.running, schedule: Schedules.withPause, elapsed: 1)
                running.snapshot = Self.snapshot(.running, stage: Schedules.withPause.stages[1])
                state = running
                expected = Card(tone: .dark, content: .pauseGlyph, name: pause, spokenValue: pause)
            case .idle:
                state = .fixture(.idle)
                expected = Card(tone: .dark, content: .pauseGlyph, name: getReady, spokenValue: getReady)
            case .paused:
                state = .fixture(.paused)
                expected = Card(tone: .dark, content: .pauseGlyph, name: pause, spokenValue: pause)
            case .awaitingUser:
                state = .fixture(.awaitingUser, schedule: Schedules.withPause)
                expected = Card(tone: .dark, content: .pauseGlyph, name: pause, spokenValue: pause)
            case .finished:
                let finished = Self.text("timer.stage.finished")
                state = .fixture(.finished)
                expected = Card(tone: .dark, content: .pauseGlyph, name: finished, spokenValue: finished)
            case .startCountdown:
                state = .fixture(.startCountdown)
                expected = Card(
                    tone: .rest,
                    content: .clock("00:03"),
                    name: getReady,
                    spokenValue: Self.spoken(getReady, Self.text("timer.countdown.start \(3)"))
                )
            case .resumeCountdown:
                var resuming = State.fixture(.resumeCountdown)
                resuming.countdown?.remaining = 2
                state = resuming
                expected = Card(
                    tone: .dark,
                    content: .countdownDigit(2),
                    name: pause,
                    spokenValue: Self.spoken(pause, Self.text("timer.countdown.resume \(2)"))
                )
        }

        #expect(state.currentCard == expected)
    }

    @Test
    func test_currentCard_clockFailed_showsTheFailureUnlessACountdownRuns() {
        var counting = State.fixture(.startCountdown)
        counting.hasClockFailed = true
        var idle = State.fixture(.idle)
        idle.hasClockFailed = true
        var paused = State.fixture(.paused)
        paused.hasClockFailed = true
        let start = Self.text("timer.failed.start")
        let resume = Self.text("timer.failed.resume")

        #expect(counting.currentCard.content == .clock("00:03"))
        #expect(idle.currentCard == Card(tone: .dark, content: .pauseGlyph, name: start, spokenValue: start))
        #expect(paused.currentCard == Card(tone: .dark, content: .pauseGlyph, name: resume, spokenValue: resume))
    }

    @Test(arguments: [
        ("", Stage.Intensity.work, Optional("timer.stage.work")),
        ("   ", .rest, "timer.stage.rest"),
        ("  Squats \n", .work, nil),
    ])
    func test_stageName_blankOrPadded_fallsBackToTheIntensityOrIsTrimmed(
        name: String,
        intensity: Stage.Intensity,
        fallbackKey: String?
    ) {
        let schedule = WorkoutSchedule(
            workout: Workout(id: UUID(fixture: 20), training: [makeStage(1, seconds: 10, intensity, name: name)])
        )
        let expected = fallbackKey.map { Self.text(String.LocalizationValue($0)) } ?? "Squats"

        #expect(State.fixture(.idle, schedule: schedule).nextStageName == expected)
        #expect(State.fixture(.running, schedule: schedule).currentCard.name == expected)
    }

    @Test
    func test_nextStageName_manualPauseComesNext_namesThePause() {
        let state = State.fixture(.running, schedule: Schedules.withPause, elapsed: 1)

        #expect(state.nextStageName == Self.text("timer.stage.pause"))
    }

    @Test
    func test_nextStageName_eachStatus_namesWhatComesNext() {
        let finished = Self.text("timer.stage.finished")

        #expect(State.fixture(.idle).nextStageName == "Stage 1")
        #expect(State.fixture(.startCountdown).nextStageName == "Stage 1")
        #expect(State.fixture(.paused).nextStageName == "Stage 1")
        #expect(State.fixture(.running).nextStageName == "Stage 2")
        #expect(State.fixture(.running, elapsed: 11).nextStageName == finished)
        #expect(State.fixture(.awaitingUser, schedule: Schedules.withPause).nextStageName == "Stage 2")
        #expect(State.fixture(.finished).nextStageName == nil)
    }

    @Test(arguments: TimerPhase.allCases)
    func test_buttons_eachPhase_followThePhase(phase: TimerPhase) {
        let state = State.fixture(phase, schedule: phase == .awaitingUser ? Schedules.withPause : Schedules.workRest)
        let expected: State.PlayButton = switch phase {
            case .startCountdown, .resumeCountdown, .running: .pause
            case .idle: .start
            case .paused, .awaitingUser, .finished: .resume
        }

        #expect(state.playButton == expected)
        #expect(state.isPlayEnabled == (phase != .finished))
        #expect(state.isNextEnabled == (phase != .finished))
    }

    @Test(arguments: [
        (Duration.zero, 0, 0),
        (.milliseconds(1), 0, 1),
        (.seconds(60), 0, 1),
        (.seconds(61), 0, 2),
        (.seconds(90), 0, 2),
        (.seconds(59 * 60 + 1), 1, 0),
        (.seconds(60 * 60), 1, 0),
        (.seconds(61 * 60), 1, 1),
        (.seconds(100 * 3_600 + 30 * 60) + .milliseconds(1), 100, 31),
    ])
    func test_totalLeft_remaining_roundsUpToWholeMinutes(remaining: Duration, hours: Int, minutes: Int) {
        var state = State.fixture(.running)
        state.snapshot = Self.snapshot(.running, totalRemaining: remaining)
        let hoursText = Self.text("timer.total.hours \(hours)")
        let minutesText = Self.text("timer.total.minutes \(minutes)")
        let expected = if hours == 0 {
            Self.text("timer.total.approximate \(minutesText)")
        } else if minutes == 0 {
            Self.text("timer.total.approximate \(hoursText)")
        } else {
            Self.text("timer.total.approximateHoursMinutes \(hoursText) \(minutesText)")
        }

        #expect(state.totalLeft == expected)
    }

    @Test
    func test_spokenTotalLeft_remaining_readsWholeMinutesRoundedUp() {
        var state = State.fixture(.running)
        state.snapshot = Self.snapshot(.running, totalRemaining: .seconds(90))
        let minutes = Duration.seconds(120).formatted(.units(allowed: [.hours, .minutes], width: .wide))

        #expect(state.spokenTotalLeft == Self.text("timer.total.spoken \(minutes)"))
    }

    @Test
    func test_progressSegments_midTraining_fillsEachRoundOfEachSection() {
        let schedule = WorkoutSchedule(
            workout: Workout(
                id: UUID(fixture: 21),
                warmUp: [makeStage(1, seconds: 10)],
                training: [makeStage(2, seconds: 5)],
                trainingRounds: 2,
                pauseAfterWarmUp: true
            )
        )
        var state = State.fixture(.idle, schedule: schedule)
        state.snapshot = Self.snapshot(.running, totalElapsed: .seconds(12))

        #expect(state.progressSegments == [
            State.ProgressSegment(weight: 10, fill: 1),
            State.ProgressSegment(weight: 5, fill: 0.4),
            State.ProgressSegment(weight: 5, fill: 0),
        ])
        #expect(State.fixture(.idle, schedule: Schedules.empty).progressSegments.isEmpty)
    }
}
