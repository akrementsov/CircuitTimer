import Foundation

/// What the Lock Screen and the Dynamic Island show for a content state, in the timer screen's
/// terms: a coloured card with the current stage and its clock, then the stage that comes next.
///
/// Once the content is stale the running stage has ended while the app slept, so the display
/// moves on to the stage the content carries and asks to open the app for anything after it.
public struct WorkoutActivityDisplay: Hashable, Sendable {
    public enum Title: Hashable, Sendable {
        case named(String)
        case untitled
    }

    public enum Tone: Hashable, Sendable {
        case work
        case rest
        /// Pauses, the start and the end, like the timer screen's pause card.
        case dark
    }

    /// Words the extension localizes; only `named` is the user's own text.
    public enum Label: Hashable, Sendable {
        case named(String)
        case work
        case rest
        case pause
        case getReady
        case finished
        case openApp
    }

    public enum Clock: Hashable, Sendable {
        /// Counts down to the upper bound on its own; the lower bound is never after it.
        case counting(ClosedRange<Date>)
        case fixed(Duration)
        case pauseGlyph
        case finishedGlyph
        case none
    }

    public struct Next: Hashable, Sendable {
        public let label: Label
        public let clock: Clock
    }

    public let title: Title
    public let tone: Tone
    public let headline: Label
    public let clock: Clock
    /// `nil` once the workout is over.
    public let next: Next?

    public init(attributes: WorkoutActivityAttributes, content: WorkoutActivityAttributes.ContentState, isStale: Bool) {
        let name = attributes.workoutName
        let title: Title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .untitled : .named(name)

        switch content.phase {
            case let .getReady(first):
                self.init(title: title, tone: .rest, headline: .getReady, clock: .none, next: Self.next(first))
            case let .running(running) where isStale:
                switch running.next {
                    case let .stage(stage, end):
                        self.init(
                            title: title,
                            tone: Self.tone(stage),
                            headline: Self.label(stage),
                            clock: Self.counting(from: running.stageEnd, to: end),
                            next: Next(label: .openApp, clock: .none)
                        )
                    case .manualPause:
                        let next = Next(label: .openApp, clock: .none)
                        self.init(title: title, tone: .dark, headline: .pause, clock: .pauseGlyph, next: next)
                    case .finish:
                        self.init(title: title, tone: .dark, headline: .finished, clock: .finishedGlyph, next: nil)
                }
            case let .running(running):
                let next = switch running.next {
                    case let .stage(stage, end):
                        Next(label: Self.label(stage), clock: Self.counting(from: running.stageEnd, to: end))
                    case .manualPause:
                        Next(label: .pause, clock: .none)
                    case .finish:
                        Next(label: .finished, clock: .none)
                }
                self.init(
                    title: title,
                    tone: Self.tone(running.stage),
                    headline: Self.label(running.stage),
                    clock: Self.counting(from: running.stageStart, to: running.stageEnd),
                    next: next
                )
            case let .paused(held):
                self.init(title: title, tone: .dark, headline: .pause, clock: .pauseGlyph, next: Self.next(held))
            case let .awaitingUser(upcoming):
                let next = upcoming.map(Self.next) ?? Next(label: .finished, clock: .none)
                self.init(title: title, tone: .dark, headline: .pause, clock: .pauseGlyph, next: next)
            case .finished:
                self.init(title: title, tone: .dark, headline: .finished, clock: .finishedGlyph, next: nil)
        }
    }

    private init(title: Title, tone: Tone, headline: Label, clock: Clock, next: Next?) {
        self.title = title
        self.tone = tone
        self.headline = headline
        self.clock = clock
        self.next = next
    }

    private static func next(_ held: WorkoutActivityAttributes.HeldStage) -> Next {
        Next(label: label(held.stage), clock: .fixed(.milliseconds(held.remainingMilliseconds)))
    }

    private static func tone(_ stage: WorkoutActivityAttributes.Stage) -> Tone {
        switch stage.kind {
            case .work:
                .work
            case .rest:
                .rest
            case .pause:
                .dark
        }
    }

    /// A blank name reads as the stage's intensity, as on the timer screen; a name shows trimmed.
    private static func label(_ stage: WorkoutActivityAttributes.Stage) -> Label {
        if let name = stage.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return .named(name)
        }
        return switch stage.kind {
            case .work:
                .work
            case .rest:
                .rest
            case .pause:
                .pause
        }
    }

    /// Dates from different readings of the clock may cross by a millisecond; a range never inverts.
    private static func counting(from start: Date, to end: Date) -> Clock {
        .counting(min(start, end)...end)
    }
}
