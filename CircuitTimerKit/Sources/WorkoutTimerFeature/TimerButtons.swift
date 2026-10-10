import DesignSystem
import SwiftUI

/// The original row: the workout list, a bordered Play/Pause in the middle and Next, sized from the row height.
struct TimerButtons: View {
    let playButton: WorkoutTimerFeature.State.PlayButton
    let isPlayEnabled: Bool
    let isNextEnabled: Bool
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.height
            // The original side buttons are 70 of the row's 98 points, aligned to its top.
            let smallSide = side * 70 / 98
            HStack(alignment: .top, spacing: .zero) {
                // TODO: [CT-3-2] The button that shows the workout's stages goes in this slot.
                Spacer()
                    .frame(width: smallSide, height: smallSide)
                Spacer(minLength: .zero)
                playPauseButton(rowHeight: side)
                Spacer(minLength: .zero)
                nextButton(side: smallSide)
            }
        }
    }

    /// Inset by its border at the top and the bottom of the row, like the original button.
    private func playPauseButton(rowHeight: CGFloat) -> some View {
        let border: CGFloat = .token(size: .buttonBorder)
        let side = rowHeight - 2 * border
        return Button(action: onPlayPause) {
            Image(systemName: playButton == .pause ? "pause.fill" : "play.fill")
                .resizable()
                .scaledToFit()
                .frame(width: rowHeight * 35 / 98, height: rowHeight * 35 / 98)
                .foregroundStyle(playColor)
                .frame(width: side, height: side)
                .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
                        .strokeBorder(playColor, lineWidth: border)
                }
        }
        .buttonStyle(.plain)
        .padding(.top, border)
        .disabled(!isPlayEnabled)
        .accessibilityLabel(playLabel)
    }

    private func nextButton(side: CGFloat) -> some View {
        Button(action: onNext) {
            Image(systemName: "forward.end.fill")
                .resizable()
                .scaledToFit()
                .frame(width: side * 26 / 70, height: side * 26 / 70)
                .foregroundStyle(isNextEnabled ? .text(.primary) : .text(.secondary))
                .frame(width: side, height: side)
                .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isNextEnabled)
        .accessibilityLabel(Text("timer.button.next", bundle: .module))
    }

    /// The glyph and the border; grey when the workout is over.
    private var playColor: Color {
        isPlayEnabled ? .text(.primary) : .text(.secondary)
    }

    private var playLabel: Text {
        switch playButton {
            case .pause: Text("timer.button.pause", bundle: .module)
            case .start: Text("timer.button.start", bundle: .module)
            case .resume: Text("timer.button.resume", bundle: .module)
        }
    }
}
