import DesignSystem
import Foundation
import SwiftUI
import WorkoutActivity

/// The workout running on the iPhone, drawn like the iPhone timer's cards, aligned to the leading edge: the running
/// stage's clock and name on its stage colour, the next stage on a dark card under it. The workout's name is the
/// screen's title. The digits count by themselves only until `digitsUntil`; the timeline hides them then even if no
/// action arrives.
///
/// The cards' text stops growing at `maxCardTextSize`, as the iPhone's card titles do, so on a 41 mm watch a stage
/// whose name takes one line keeps the next stage on screen; a longer name shows whole and scrolls. The note under the
/// cards follows the user's text size.
struct WatchRunView: View {
    let screen: WatchRemoteFeature.State.RunScreen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .token(spacing: .xs)) {
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

    private static let maxCardTextSize = DynamicTypeSize.xLarge

    private var display: WorkoutActivityDisplay {
        screen.display
    }

    /// The digits show only while the iPhone's confirmation holds: the timeline redraws the card at `digitsUntil`, and
    /// the screen and VoiceOver read the same answer for the same date. One timeline in every state keeps the card the
    /// same view, so VoiceOver's focus stays on it when a lease opens or ends.
    private var card: some View {
        TimelineView(.explicit(digitsSchedule)) { context in
            stageCard(showsDigits: screen.showsDigits(at: context.date))
        }
    }

    /// The first entry is always past, so the timeline draws at once, as SwiftUI documents for a past date; under a
    /// lease the second hides the digits.
    private var digitsSchedule: [Date] {
        guard let from = screen.digitsFrom, let until = screen.digitsUntil else { return [.distantPast] }
        return [min(from, until), until]
    }

    private func stageCard(showsDigits: Bool) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            switch display.clock {
                case let .counting(range):
                    digits(showsDigits) { WatchClockText(range: range) }
                    headline
                case .pauseGlyph:
                    // The glyph stands beside the word, so the time left fits under them.
                    HStack(spacing: .token(spacing: .xs)) {
                        glyph("pause.fill")
                        headline
                    }
                    if case let .fixed(remaining) = display.islandClock {
                        digits(showsDigits) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, .token(spacing: .s))
        .padding(.vertical, .token(spacing: .s))
        .background(display.tone.fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .dynamicTypeSize(...Self.maxCardTextSize)
        // One element, as on the iPhone: the stage's name, then its time while the iPhone's confirmation holds.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(display.headline))
        .accessibilityValue(spokenTime(showsDigits))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The time the card shows, for VoiceOver; nothing when the screen shows none.
    private func spokenTime(_ showsDigits: Bool) -> Text {
        guard showsDigits else { return Text(verbatim: "") }
        switch display.clock {
            case let .counting(range):
                return Text(timerInterval: range, countsDown: true, showsHours: false)
            case .pauseGlyph:
                guard case let .fixed(remaining) = display.islandClock else { return Text(verbatim: "") }
                return Text(verbatim: remaining.clockText(.timerRemaining))
            case .finishedGlyph, .fixed, .none:
                return Text(verbatim: "")
        }
    }

    private var headline: some View {
        Text(display.headline)
            .font(.token(.runningStageName))
            .textCase(.uppercase)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// As on the iPhone: what comes next, without its length, which starts only when the running stage ends.
    private func nextCard(_ next: WorkoutActivityDisplay.Next) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text("watch.run.next", bundle: .module)
                .font(.token(.note))
                .foregroundStyle(.text(.secondary))
                .lineLimit(1)
            Text(next.label)
                .font(.token(.nextStageName))
                .foregroundStyle(.text(.primary))
                .textCase(.uppercase)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, .token(spacing: .s))
        .padding(.vertical, .token(spacing: .xs))
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .dynamicTypeSize(...Self.maxCardTextSize)
        .accessibilityElement(children: .combine)
    }

    /// Without the digits a hidden reading keeps their place, so the cards do not jump when they go and come back.
    @ViewBuilder private func digits(_ showsDigits: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        if showsDigits {
            content()
        } else {
            digitsPlace
        }
    }

    private var digitsPlace: some View {
        Text(verbatim: "2:22")
            .font(.token(.runningStageClock))
            .hidden()
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
