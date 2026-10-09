import DesignSystem
import SwiftUI

/// The rough time left in the workout.
struct TotalCard: View {
    let value: String
    let spokenValue: String

    var body: some View {
        VStack(spacing: .token(spacing: .m)) {
            CardTitle("timer.card.total")
            GeometryReader { proxy in
                Text(value)
                    .font(.token(.totalClock, fitting: proxy.size))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    // The font is sized for its cap height, so its line overflows the box; only the width may shrink it.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .foregroundStyle(.text(.secondary))
        .padding(.top, .token(spacing: .m))
        .padding([.horizontal, .bottom], .token(spacing: .l))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("timer.card.total", bundle: .module))
        .accessibilityValue(spokenValue)
    }
}

/// The stage being played: its time, a countdown or the pause glyph, and its name.
struct CurrentStageCard: View {
    let card: WorkoutTimerFeature.State.CurrentCard

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: .zero) {
                CardTitle("timer.card.current")
                    .foregroundStyle(titleColor)
                content
                    .foregroundStyle(contentColor)
                    // The original card gives the clock 136 of its 289 points.
                    .frame(height: proxy.size.height * 136 / 289)
                    .padding(.top, .token(spacing: .l))
                StageName(card.name)
                    .foregroundStyle(contentColor)
                    .padding(.top, .token(spacing: .m))
                    .padding(.bottom, .token(spacing: .s))
            }
            .padding(.top, .token(spacing: .m))
            .padding(.horizontal, .token(spacing: .l))
        }
        .background(fill, in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("timer.card.current", bundle: .module))
        .accessibilityValue(card.spokenValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var content: some View {
        switch card.content {
            case let .clock(text):
                StageClockText(text)
            case let .countdownDigit(digit):
                StageClockText("\(digit)")
            case .pauseGlyph:
                Image(systemName: "pause.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fill: Color {
        switch card.tone {
            case .work: .stage(.work)
            case .rest: .stage(.rest)
            case .dark: .stage(.pause)
        }
    }

    private var titleColor: Color {
        card.tone == .dark ? .text(.secondary) : .text(.onAccent)
    }

    private var contentColor: Color {
        card.tone == .dark ? .text(.primary) : .text(.onAccent)
    }
}

/// The stage after the current one; empty once the workout is over.
struct NextStageCard: View {
    let name: String?

    var body: some View {
        VStack(spacing: .token(spacing: .xs)) {
            CardTitle("timer.card.next")
                .foregroundStyle(.text(.secondary))
            StageName(name ?? "")
                .foregroundStyle(.text(.primary))
        }
        .padding(.top, .token(spacing: .m))
        .padding(.horizontal, .token(spacing: .l))
        .padding(.bottom, .token(spacing: .xs))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("timer.card.next", bundle: .module))
        .accessibilityValue(name ?? "")
    }
}

private struct CardTitle: View {
    let key: LocalizedStringKey

    init(_ key: LocalizedStringKey) {
        self.key = key
    }

    var body: some View {
        Text(key, bundle: .module)
            .font(.token(.headline))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // The cards keep their height, so the title stops growing before it crowds out the stage.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// A stage name in capitals, up to two lines, sized from the box it gets.
private struct StageName: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        GeometryReader { proxy in
            Text(name)
                .font(.token(.stageName, fitting: proxy.size))
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.3)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
