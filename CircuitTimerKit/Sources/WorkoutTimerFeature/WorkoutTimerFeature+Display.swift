import DesignSystem
import Foundation
import WorkoutDomain

// What the timer screen shows, derived from the state after the original app's timer.
extension WorkoutTimerFeature.State {
    struct CurrentCard: Equatable {
        enum Tone: Equatable {
            case work
            case rest
            /// The pause card: user and manual pauses, the start before any countdown, the end and a stopped clock.
            case dark
        }

        enum Content: Equatable {
            case clock(String)
            /// The stay countdown, one big digit in place of the pause glyph.
            case countdownDigit(Int)
            case pauseGlyph
        }

        let tone: Tone
        let content: Content
        /// Shown in capitals.
        let name: String
        /// What VoiceOver reads after the card's title.
        let spokenValue: String
    }

    enum PlayButton: Equatable {
        /// A countdown or a stage is running; the button stops it.
        case pause
        case start
        case resume
    }

    struct ProgressSegment: Equatable {
        /// The segment's share of the bar, in seconds of the schedule.
        let weight: Double
        /// How much of the segment is done, `0...1`.
        let fill: Double
    }

    var currentCard: CurrentCard {
        if let countdown {
            return countdownCard(countdown)
        }
        if hasClockFailed {
            let message = snapshot.status == .idle
                ? String(localized: "timer.failed.start", bundle: .module)
                : String(localized: "timer.failed.resume", bundle: .module)
            return CurrentCard(tone: .dark, content: .pauseGlyph, name: message, spokenValue: message)
        }

        let name: String
        switch snapshot.status {
            case .idle:
                name = String(localized: "timer.stage.getReady", bundle: .module)
            case .running:
                if let stage = snapshot.currentStage, stage.kind != .pause {
                    return runningCard(stage)
                }
                name = String(localized: "timer.stage.pause", bundle: .module)
            case .paused, .awaitingUser:
                name = String(localized: "timer.stage.pause", bundle: .module)
            case .finished:
                name = String(localized: "timer.stage.finished", bundle: .module)
        }
        return CurrentCard(tone: .dark, content: .pauseGlyph, name: name, spokenValue: name)
    }

    /// `nil` once the workout is over: the next card stays empty.
    var nextStageName: String? {
        switch snapshot.status {
            case .finished:
                return nil
            case .idle, .paused:
                // Before the start the first stage comes next; a user pause resumes the stage it stopped.
                return snapshot.currentStage.map(Self.displayName)
            case .running, .awaitingUser:
                return snapshot.nextStage.map(Self.displayName) ?? String(localized: "timer.stage.finished", bundle: .module)
        }
    }

    /// The legacy rough total, `~2 МИН` or `~1 ЧАС 5 МИН`, rounded up to whole minutes.
    var totalLeft: String {
        let minutes = Self.minutesRoundedUp(snapshot.totalRemaining)
        let hours = minutes / 60
        let restMinutes = minutes % 60
        let hoursText = String(localized: "timer.total.hours \(hours)", bundle: .module)
        let minutesText = String(localized: "timer.total.minutes \(restMinutes)", bundle: .module)
        if hours == 0 {
            return String(localized: "timer.total.approximate \(minutesText)", bundle: .module)
        }
        if restMinutes == 0 {
            return String(localized: "timer.total.approximate \(hoursText)", bundle: .module)
        }
        return String(localized: "timer.total.approximateHoursMinutes \(hoursText) \(minutesText)", bundle: .module)
    }

    var spokenTotalLeft: String {
        let minutes = Duration.seconds(Self.minutesRoundedUp(snapshot.totalRemaining) * 60)
        let spoken = minutes.formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return String(localized: "timer.total.spoken \(spoken)", bundle: .module)
    }

    /// One segment per round of each section, like the original bar.
    var progressSegments: [ProgressSegment] {
        run.schedule.segments.map { segment in
            ProgressSegment(
                weight: (segment.range.upperBound - segment.range.lowerBound) / .seconds(1),
                fill: segment.progress(at: snapshot.totalElapsed)
            )
        }
    }

    var playButton: PlayButton {
        if countdown != nil || snapshot.status == .running {
            return .pause
        }
        return snapshot.status == .idle ? .start : .resume
    }

    var isPlayEnabled: Bool {
        snapshot.status != .finished
    }

    var isNextEnabled: Bool {
        snapshot.status != .finished
    }

    private func countdownCard(_ countdown: WorkoutTimerFeature.Countdown) -> CurrentCard {
        switch countdown.purpose {
            case .start:
                let name = String(localized: "timer.stage.getReady", bundle: .module)
                let spoken = String(localized: "timer.countdown.start \(countdown.remaining)", bundle: .module)
                return CurrentCard(
                    tone: .rest,
                    content: .clock(Duration.seconds(countdown.remaining).clockText(.minutesSeconds)),
                    name: name,
                    spokenValue: String(localized: "timer.current.spoken \(name) \(spoken)", bundle: .module)
                )
            case .resume:
                let name = String(localized: "timer.stage.pause", bundle: .module)
                let spoken = String(localized: "timer.countdown.resume \(countdown.remaining)", bundle: .module)
                return CurrentCard(
                    tone: .dark,
                    content: .countdownDigit(countdown.remaining),
                    name: name,
                    spokenValue: String(localized: "timer.current.spoken \(name) \(spoken)", bundle: .module)
                )
        }
    }

    private func runningCard(_ stage: ScheduledStage) -> CurrentCard {
        let name = Self.displayName(stage)
        let remaining = Duration.seconds(Self.secondsRoundedUp(snapshot.stageRemaining))
        let spoken = remaining.formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        return CurrentCard(
            tone: stage.kind == .rest ? .rest : .work,
            content: .clock(snapshot.stageRemaining.clockText(.remaining)),
            name: name,
            spokenValue: String(localized: "timer.current.spoken \(name) \(spoken)", bundle: .module)
        )
    }

    /// A blank name reads as the stage's intensity in the current language; storage keeps it blank.
    private static func displayName(_ stage: ScheduledStage) -> String {
        if let name = stage.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return switch stage.kind {
            case .work:
                String(localized: "timer.stage.work", bundle: .module)
            case .rest:
                String(localized: "timer.stage.rest", bundle: .module)
            case .pause:
                String(localized: "timer.stage.pause", bundle: .module)
        }
    }

    private static func secondsRoundedUp(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return attoseconds > 0 ? seconds + 1 : seconds
    }

    private static func minutesRoundedUp(_ duration: Duration) -> Int64 {
        (secondsRoundedUp(duration) + 59) / 60
    }
}
