import DesignSystem
import Foundation
import SwiftUI
import WorkoutActivity
import WorkoutDomain

/// The workout running on the iPhone, drawn like its Live Activity card. The digits count by themselves only until
/// `digitsUntil`; the timeline hides them then even if no action arrives.
struct WatchRunView: View {
    let screen: WatchRemoteFeature.State.RunScreen

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                card
                if let next = display.next {
                    nextRow(next)
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
        VStack(alignment: .leading, spacing: .token(spacing: .xxs)) {
            Text(display.title)
                .font(.token(.note))
                .lineLimit(1)
            Text(display.headline)
                .font(.token(.runningStageName))
                .lineLimit(2)
            clock
        }
        .foregroundStyle(display.tone.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.token(spacing: .s))
        .background(display.tone.fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }

    @ViewBuilder private var clock: some View {
        switch display.clock {
            case let .counting(range):
                digits { WatchClockText(range: range) }
            case .pauseGlyph:
                HStack(spacing: .token(spacing: .xs)) {
                    glyph("pause.fill")
                    if case let .fixed(remaining) = display.islandClock {
                        digits {
                            Text(verbatim: remaining.clockText(.timerRemaining))
                                .font(.token(.runningStageClock))
                        }
                    }
                }
            case .finishedGlyph:
                glyph("checkmark")
            case .fixed, .none:
                EmptyView()
        }
    }

    private func nextRow(_ next: WorkoutActivityDisplay.Next) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("watch.run.next", bundle: .module)
                    .font(.token(.note))
                    .foregroundStyle(.text(.secondary))
                Text(next.label)
                    .font(.token(.nextStageName))
                    .foregroundStyle(next.tone.accent)
                    .lineLimit(2)
            }
            Spacer(minLength: .token(spacing: .xs))
            if let duration = next.clock.duration {
                digits {
                    Text(verbatim: duration.clockText(.timerRemaining))
                        .font(.token(.nextStageClock))
                        .foregroundStyle(.text(.primary))
                }
            }
        }
    }

    /// Shown only while the iPhone's confirmation holds: the timeline redraws at `digitsUntil` and hides them then.
    @ViewBuilder private func digits(@ViewBuilder _ content: @escaping () -> some View) -> some View {
        if let until = screen.digitsUntil {
            TimelineView(.explicit([until])) { context in
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
        Text(verbatim: range.upperBound.timeIntervalSince(range.lowerBound).rounded() >= 600 ? "22:22" : "2:22")
            .hidden()
            .overlay(alignment: .leading) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
                    .minimumScaleFactor(0.9)
            }
            .font(.token(.runningStageClock))
    }
}

private extension WorkoutActivityDisplay.Clock {
    /// A next stage's length, which the watch shows still: it starts only when the running stage ends.
    var duration: Duration? {
        switch self {
            case let .counting(range):
                range.upperBound.elapsed(since: range.lowerBound)
            case let .fixed(duration):
                duration
            case .pauseGlyph, .finishedGlyph, .none:
                nil
        }
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

    /// A next stage's name on the screen's black.
    var accent: Color {
        switch self {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
            case .dark: .text(.primary)
        }
    }
}
