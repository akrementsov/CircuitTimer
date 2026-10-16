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
                // A counting text takes all the width it is offered; trailing alignment keeps the digits at the edge.
                Text(timerInterval: range, countsDown: true, showsHours: false)
                    .font(.token(style))
                    .multilineTextAlignment(.trailing)
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

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: glyphSide, height: glyphSide)
    }
}

extension WorkoutActivityDisplay {
    /// The Dynamic Island shows a held stage's time where the Lock Screen shows the pause glyph.
    var islandClock: Clock {
        if case .pauseGlyph = clock, let next, case .fixed = next.clock {
            return next.clock
        }
        return clock
    }
}
