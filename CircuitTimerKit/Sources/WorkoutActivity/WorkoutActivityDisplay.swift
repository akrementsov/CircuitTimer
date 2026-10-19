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
        /// Pauses and the end, like the timer screen's pause card. The start takes `rest`, like its 3-2-1.
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
        /// The colour the stage will take; the Dynamic Island draws its name in it.
        public let tone: Tone
        public let clock: Clock
    }

    public let title: Title
    public let tone: Tone
    public let headline: Label
    public let clock: Clock
    /// What the Dynamic Island's clock shows. It has no row for a paused stage's time left, which the Lock Screen
    /// shows under the pause glyph, so a stage the user paused shows that time instead; everything else is `clock`.
    public let islandClock: Clock
    /// `nil` once the workout is over.
    public let next: Next?

    /// The single action matching the stage this projection shows, including stale content.
    public var control: LiveActivityCommand? {
        switch clock {
            case .counting:
                .pause
            case .pauseGlyph:
                .resume
            case .fixed, .finishedGlyph, .none:
                nil
        }
    }

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
                            next: Next(label: .openApp, tone: .dark, clock: .none)
                        )
                    case .manualPause:
                        let next = Next(label: .openApp, tone: .dark, clock: .none)
                        self.init(title: title, tone: .dark, headline: .pause, clock: .pauseGlyph, next: next)
                    case .finish:
                        self.init(title: title, tone: .dark, headline: .finished, clock: .finishedGlyph, next: nil)
                }
            case let .running(running):
                let next = switch running.next {
                    case let .stage(stage, end):
                        Next(label: Self.label(stage), tone: Self.tone(stage), clock: Self.counting(from: running.stageEnd, to: end))
                    case .manualPause:
                        Next(label: .pause, tone: .dark, clock: .none)
                    case .finish:
                        Next(label: .finished, tone: .dark, clock: .none)
                }
                self.init(
                    title: title,
                    tone: Self.tone(running.stage),
                    headline: Self.label(running.stage),
                    clock: Self.counting(from: running.stageStart, to: running.stageEnd),
                    next: next
                )
            case let .paused(held):
                self.init(
                    title: title,
                    tone: .dark,
                    headline: .pause,
                    clock: .pauseGlyph,
                    islandClock: .fixed(.milliseconds(held.remainingMilliseconds)),
                    next: Self.next(held)
                )
            case let .awaitingUser(upcoming):
                let next = upcoming.map(Self.next) ?? Next(label: .finished, tone: .dark, clock: .none)
                self.init(title: title, tone: .dark, headline: .pause, clock: .pauseGlyph, next: next)
            case .finished:
                self.init(title: title, tone: .dark, headline: .finished, clock: .finishedGlyph, next: nil)
        }
    }

    private init(title: Title, tone: Tone, headline: Label, clock: Clock, islandClock: Clock? = nil, next: Next?) {
        self.title = title
        self.tone = tone
        self.headline = headline
        self.clock = clock
        self.islandClock = islandClock ?? clock
        self.next = next
    }

    private static func next(_ held: WorkoutActivityAttributes.HeldStage) -> Next {
        Next(label: label(held.stage), tone: tone(held.stage), clock: .fixed(.milliseconds(held.remainingMilliseconds)))
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
