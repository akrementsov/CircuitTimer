import DesignSystem
import Foundation
import SwiftUI
import WorkoutActivity
import WorkoutDomain

/// The workout running on the iPhone, drawn like the iPhone timer's cards: the running stage's clock and name on its
/// stage colour, the next stage on a dark card under it. The workout's name is the screen's title. The digits count by
/// themselves only until `digitsUntil`; the timeline hides them then even if no action arrives.
struct WatchRunView: View {
    let screen: WatchRemoteFeature.State.RunScreen

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                card
                if let next = display.next {
                    nextCard(next)
                }
                if let note = screen.note {
                    noteText(note)
                }
            }
        }
    }

    private var display: WorkoutActivityDisplay {
        screen.display
    }

    private var card: some View {
        VStack(spacing: .zero) {
            switch display.clock {
                case let .counting(range):
                    digits { WatchClockText(range: range) }
                    headline
                case .pauseGlyph:
                    // The glyph stands beside the word, so the time left fits under them.
                    HStack(spacing: .token(spacing: .xs)) {
                        glyph("pause.fill")
                        headline
                    }
                    if case let .fixed(remaining) = display.islandClock {
                        digits {
                            Text(verbatim: remaining.clockText(.timerRemaining))
                                .font(.token(.runningStageClock))
                        }
                    }
                case .finishedGlyph:
                    HStack(spacing: .token(spacing: .xs)) {
                        glyph("checkmark")
                        headline
                    }
                case .fixed, .none:
                    headline
            }
        }
        .foregroundStyle(display.tone.ink)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, .token(spacing: .xs))
        .padding(.vertical, .token(spacing: .s))
        .background(display.tone.fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }

    private var headline: some View {
        Text(display.headline)
            .font(.token(.runningStageName))
            .textCase(.uppercase)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }

    /// As on the iPhone: what comes next, without its length, which starts only when the running stage ends.
    private func nextCard(_ next: WorkoutActivityDisplay.Next) -> some View {
        VStack(spacing: .zero) {
            Text("watch.run.next", bundle: .module)
                .font(.token(.note))
                .foregroundStyle(.text(.secondary))
                .lineLimit(1)
            Text(next.label)
                .font(.token(.nextStageName))
                .foregroundStyle(.text(.primary))
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, .token(spacing: .xs))
        .padding(.vertical, .token(spacing: .xs))
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }

    /// Shown only while the iPhone's confirmation holds: the timeline redraws at `digitsUntil` and hides them then.
    @ViewBuilder private func digits(@ViewBuilder _ content: @escaping () -> some View) -> some View {
        if let from = screen.digitsFrom, let until = screen.digitsUntil {
            // The first entry is already past, so the timeline draws at once; the second hides the digits.
            TimelineView(.explicit([min(from, until), until])) { context in
                if screen.showsDigits(at: context.date) {
                    content()
                }
            }
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.token(.runningStageName))
            .accessibilityHidden(true)
    }

    private func noteText(_ note: WatchRemoteFeature.State.RunNote) -> some View {
        Group {
            switch note {
                case .waiting:
                    Text("watch.run.waiting", bundle: .module)
                case .unreachable:
                    Text("watch.link.unreachable.title", bundle: .module)
                case .unlock:
                    Text("watch.link.unlock.title", bundle: .module)
            }
        }
        .font(.token(.note))
        .foregroundStyle(.text(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A stage clock that counts on its own. It has no width of its own, so a hidden template of the longest reading gives
/// it one, as on the Live Activity.
struct WatchClockText: View {
    let range: ClosedRange<Date>

    var body: some View {
        Text(verbatim: Self.template(for: range))
            .hidden()
            .overlay(alignment: .leading) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
                    .minimumScaleFactor(0.9)
            }
            .font(.token(.runningStageClock))
    }

    /// Ten minutes, from which the minutes take two digits.
    private static let twoDigitMinutes: TimeInterval = 600

    /// `2:22`, or `22:22` from ten minutes on: 2 is League Gothic's widest digit, and `WorkoutLimits` keeps a stage
    /// under 100 minutes, so the minutes never take three digits. Whole seconds decide, as on the Live Activity.
    private static func template(for range: ClosedRange<Date>) -> String {
        range.upperBound.timeIntervalSince(range.lowerBound).rounded() >= twoDigitMinutes ? "22:22" : "2:22"
    }
}

extension Text {
    init(_ title: WorkoutActivityDisplay.Title) {
        switch title {
            case let .named(name):
                self.init(verbatim: name)
            case .untitled:
                self.init("watch.workout.untitled", bundle: .module)
        }
    }

    init(_ label: WorkoutActivityDisplay.Label) {
        switch label {
            case let .named(name):
                self.init(verbatim: name)
            case .work:
                self.init("watch.run.stage.work", bundle: .module)
            case .rest:
                self.init("watch.run.stage.rest", bundle: .module)
            case .pause:
                self.init("watch.run.stage.pause", bundle: .module)
            case .getReady:
                self.init("watch.run.getReady", bundle: .module)
            case .finished:
                self.init("watch.run.finished", bundle: .module)
            case .openApp:
                self.init("watch.run.openPhone", bundle: .module)
        }
    }
}

extension WorkoutActivityDisplay.Tone {
    var fill: Color {
        switch self {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
            case .dark: .stage(.pause)
        }
    }

    /// Text on `fill`.
    var ink: Color {
        self == .dark ? .text(.primary) : .text(.onAccent)
    }
}
