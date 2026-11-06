import DesignSystem
import Foundation
import SwiftUI
import WorkoutActivity

/// The workout running on the iPhone, drawn like the iPhone timer's cards, aligned to the leading edge: the running
/// stage's clock and name on its stage colour with Pause or Resume at its trailing edge, the next stage on a dark card
/// under it. The workout's name is the screen's title. The digits count by themselves only until `digitsUntil`; the
/// timeline hides them then even if no action arrives.
///
/// The cards' text stops growing at `maxCardTextSize`, as the iPhone's card titles do, so on a 41 mm watch a stage
/// whose name takes one line keeps the next stage on screen; a longer name shows whole and scrolls. The note under the
/// cards follows the user's text size.
struct WatchRunView: View {
    let screen: WatchRemoteFeature.State.RunScreen
    let onControl: () -> Void

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

    /// The control's strip at the stage card's trailing edge: the 44 pt target, the gap before it and the card's own
    /// padding after it, all of it tappable.
    private static let controlStripWidth: CGFloat =
        .token(size: .watchControl) + .token(spacing: .xs) + .token(spacing: .s)

    private var display: WorkoutActivityDisplay {
        screen.display
    }

    /// The digits show only while the iPhone's confirmation holds: the timeline redraws the card at `digitsUntil`, and
    /// the screen and VoiceOver read the same answer for the same date. One timeline in every state keeps the card the
    /// same view, so VoiceOver's focus stays on it when a lease opens or ends.
    ///
    /// Pause or Resume lies over the card's trailing strip, the card's full height, as a separate element after it.
    private var card: some View {
        TimelineView(.explicit(digitsSchedule)) { context in
            stageCard(showsDigits: screen.showsDigits(at: context.date))
        }
        .overlay(alignment: .trailing) {
            control
        }
    }

    /// The card keeps the strip whenever the phase has a control, so nothing on it moves as the button comes and goes.
    private var hasControlStrip: Bool {
        screen.controlSlot != .none
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
                    clock { style in
                        digits(showsDigits, holding: WatchClockText.template(for: range), style: style) {
                            WatchClockText(range: range, style: style)
                        }
                    }
                    headline
                case .pauseGlyph:
                    // The glyph stands beside the word, so the time left fits under them.
                    HStack(spacing: .token(spacing: .xs)) {
                        glyph("pause.fill")
                        headline
                    }
                    if case let .fixed(remaining) = display.islandClock {
                        let reading = remaining.clockText(.timerRemaining)
                        clock { style in
                            digits(showsDigits, holding: reading, style: style) {
                                Text(verbatim: reading)
                                    .font(.token(style))
                            }
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
        .padding(.leading, .token(spacing: .s))
        .padding(.trailing, hasControlStrip ? .zero : .token(spacing: .s))
        .padding(.vertical, .token(spacing: .s))
        // One element, as on the iPhone: the stage's name, then its time while the iPhone's confirmation holds. It
        // ends where the control's strip begins, so Pause or Resume over the strip is an element of its own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(display.headline))
        .accessibilityValue(spokenTime(showsDigits))
        .accessibilityAddTraits(.updatesFrequently)
        .padding(.trailing, hasControlStrip ? Self.controlStripWidth : .zero)
        .background(display.tone.fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .dynamicTypeSize(...Self.maxCardTextSize)
    }

    /// The clock at full size, or smaller where that does not fit beside the control's strip. Both candidates measure
    /// the same template whether the digits show or not, so the size never changes when they come and go.
    private func clock<Content: View>(
        @ViewBuilder _ content: (DesignSystem.Token.WatchTypography) -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            content(.runningStageClock)
            content(.runningStageClockCompact)
        }
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

    /// Pause or Resume on the stage card's trailing strip. The card's padding keeps the strip, so without a confirmation
    /// it stays empty and nothing on the card moves when the button comes back; a phase without a control has no
    /// strip.
    @ViewBuilder private var control: some View {
        if case let .button(control) = screen.controlSlot {
            // Gone at the stage's or the lease's end even if no action redraws the screen then.
            TimelineView(.explicit([.distantPast, control.until])) { context in
                if context.date < control.until {
                    controlButton(control.command, isEnabled: control.isEnabled)
                }
            }
        }
    }

    private func controlName(_ command: LiveActivityCommand) -> Text {
        switch command {
            case .pause: Text("watch.run.control.pause", bundle: .module)
            case .resume: Text("watch.run.control.resume", bundle: .module)
        }
    }

    /// The whole strip is the button: its label fills the strip's width and the card's height, so a tap anywhere along
    /// the card's trailing edge counts. The circle only marks it, in the card's ink, like the iPhone timer's round
    /// buttons.
    private func controlButton(_ command: LiveActivityCommand, isEnabled: Bool) -> some View {
        Button(action: onControl) {
            ZStack {
                Circle()
                    .strokeBorder(display.tone.ink, lineWidth: .token(size: .buttonBorder))
                Image(systemName: command == .pause ? "pause.fill" : "play.fill")
                    .font(.token(.control))
                    .foregroundStyle(display.tone.ink)
            }
            .frame(width: .token(size: .watchControl), height: .token(size: .watchControl))
            // The strip's width is the card's reserved padding: one constant, so the two never drift apart.
            .frame(width: Self.controlStripWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : .token(opacity: .disabled))
        .accessibilityLabel(controlName(command))
        .dynamicTypeSize(...Self.maxCardTextSize)
    }

    /// Without the digits a hidden `template` keeps their place, so the cards do not jump when they go and come back.
    @ViewBuilder private func digits(
        _ showsDigits: Bool,
        holding template: String,
        style: DesignSystem.Token.WatchTypography,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        if showsDigits {
            content()
        } else {
            Text(verbatim: template)
                .font(.token(style))
                .hidden()
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
                case .commandChecking:
                    Text("watch.run.command.checking", bundle: .module)
                case .commandChanged:
                    Text("watch.run.command.changed", bundle: .module)
                case .commandFailed:
                    Text("watch.run.command.failed", bundle: .module)
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
    var style = DesignSystem.Token.WatchTypography.runningStageClock

    var body: some View {
        Text(verbatim: Self.template(for: range))
            .hidden()
            .overlay(alignment: .leading) {
                Text(timerInterval: range, countsDown: true, showsHours: false)
                    .minimumScaleFactor(0.9)
            }
            .font(.token(style))
    }

    /// Ten minutes, from which the minutes take two digits.
    private static let twoDigitMinutes: TimeInterval = 600

    /// `2:22`, or `22:22` from ten minutes on: 2 is League Gothic's widest digit, and `WorkoutLimits` keeps a stage
    /// under 100 minutes, so the minutes never take three digits. Whole seconds decide, as on the Live Activity.
    static func template(for range: ClosedRange<Date>) -> String {
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
