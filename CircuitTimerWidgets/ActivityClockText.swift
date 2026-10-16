import DesignSystem
import SwiftUI
import WorkoutActivity

/// A stage clock that counts on its own, a held time, or the glyph that stands in for one.
struct ActivityClockText: View {
    private let clock: WorkoutActivityDisplay.Clock
    private let style: DesignSystem.Token.ActivityTypography
    private let glyphSide: CGFloat

    init(_ clock: WorkoutActivityDisplay.Clock, style: DesignSystem.Token.ActivityTypography, glyphSide: CGFloat) {
        self.clock = clock
        self.style = style
        self.glyphSide = glyphSide
    }

    var body: some View {
        switch clock {
            case let .counting(range):
                // A counting text has no width of its own: it takes all it is offered, and a fixed size breaks the
                // layout. A hidden template of the longest reading gives it one.
                Text(verbatim: Self.template(for: range))
                    .hidden()
                    .overlay(alignment: .trailing) {
                        Text(timerInterval: range, countsDown: true, showsHours: false)
                            .multilineTextAlignment(.trailing)
                            // A rounding overflow shrinks the digits a little instead of truncating them.
                            .minimumScaleFactor(0.9)
                    }
                    .font(.token(style))
            case let .fixed(duration):
                Text(verbatim: duration.clockText(.timerRemaining))
                    .font(.token(style))
            case .pauseGlyph:
                glyph("pause.fill")
            case .finishedGlyph:
                glyph("checkmark")
            case .none:
                EmptyView()
        }
    }

    /// Ten minutes, from which the minutes take two digits.
    private static let twoDigitMinutes: TimeInterval = 600

    /// `2:22`, or `22:22` from ten minutes on: 2 is League Gothic's widest digit, and `WorkoutLimits` keeps a stage
    /// under 100 minutes, so the minutes never take three digits.
    private static func template(for range: ClosedRange<Date>) -> String {
        range.upperBound.timeIntervalSince(range.lowerBound) >= twoDigitMinutes ? "22:22" : "2:22"
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: glyphSide, height: glyphSide)
    }
}
