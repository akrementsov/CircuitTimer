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
            let message = snapshot.status == .idle ? Self.text("timer.failed.start") : Self.text("timer.failed.resume")
            return CurrentCard(tone: .dark, content: .pauseGlyph, name: message, spokenValue: message)
        }

        let name: String
        switch snapshot.status {
            case .idle:
                name = Self.text("timer.stage.getReady")
            case .running:
                if let stage = snapshot.currentStage, stage.kind != .pause {
                    return runningCard(stage)
                }
                name = Self.text("timer.stage.pause")
            case .paused, .awaitingUser:
                name = Self.text("timer.stage.pause")
            case .finished:
                name = Self.text("timer.stage.finished")
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
                return snapshot.nextStage.map(Self.displayName) ?? Self.text("timer.stage.finished")
        }
    }

    /// The legacy rough total, `~2 МИН` or `~1 ЧАС 5 МИН`, rounded up to whole minutes.
    var totalLeft: String {
        let minutes = Self.minutesRoundedUp(snapshot.totalRemaining)
        let hours = minutes / 60
        let restMinutes = minutes % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(String(localized: "timer.total.hours \(hours)", bundle: .module))
        }
        if hours == 0 || restMinutes > 0 {
            parts.append(String(localized: "timer.total.minutes \(restMinutes)", bundle: .module))
        }
        return "~" + parts.joined(separator: " ")
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
                let name = Self.text("timer.stage.getReady")
                let spoken = String(localized: "timer.countdown.start \(countdown.remaining)", bundle: .module)
                return CurrentCard(
                    tone: .rest,
                    content: .clock(Duration.seconds(countdown.remaining).clockText(.minutesSeconds)),
                    name: name,
                    spokenValue: "\(name), \(spoken)"
                )
            case .resume:
                let name = Self.text("timer.stage.pause")
                let spoken = String(localized: "timer.countdown.resume \(countdown.remaining)", bundle: .module)
                return CurrentCard(tone: .dark, content: .countdownDigit(countdown.remaining), name: name, spokenValue: "\(name), \(spoken)")
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
            spokenValue: "\(name), \(spoken)"
        )
    }

    /// A blank name reads as the stage's intensity in the current language; storage keeps it blank.
    private static func displayName(_ stage: ScheduledStage) -> String {
        if let name = stage.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return switch stage.kind {
            case .work:
                text("timer.stage.work")
            case .rest:
                text("timer.stage.rest")
            case .pause:
                text("timer.stage.pause")
        }
    }

    private static func secondsRoundedUp(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return attoseconds > 0 ? seconds + 1 : seconds
    }

    private static func minutesRoundedUp(_ duration: Duration) -> Int64 {
        (secondsRoundedUp(duration) + 59) / 60
    }

    private static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}
