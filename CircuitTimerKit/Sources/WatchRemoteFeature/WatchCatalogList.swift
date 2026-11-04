import DesignSystem
import Foundation
import SwiftUI
import WatchLink

/// The iPhone's workouts; choosing one opens its explicit Start screen.
struct WatchCatalogList: View {
    let catalog: WatchCatalog
    /// Set when the iPhone could not load a newer list; this one is the last it had.
    let dimmed: UnavailableReason?
    let status: WatchRemoteFeature.State.StatusLine?
    var startNote: WatchRemoteFeature.StartNote?
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                if let startNote { WatchStartStatusView(note: startNote) }
                // Why the list may be old comes first; a dimmed list then says why the iPhone sent no newer one.
                if let status {
                    WatchStatusText(status: status)
                }
                if let dimmed {
                    note(dimmed == .tooLarge
                        ? Text("watch.catalog.tooLarge.note", bundle: .module)
                        : Text("watch.catalog.loadFailed.note", bundle: .module))
                }
                ForEach(catalog.entries) { entry in
                    Button { onSelect(entry.id) } label: {
                        WatchWorkoutRow(entry: entry, isDimmed: dimmed != nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("watch.workout.choose", bundle: .module))
                }
                if catalog.isTruncated {
                    note(Text("watch.catalog.truncated", bundle: .module))
                }
            }
        }
    }

    private func note(_ text: Text) -> some View {
        text
            .font(.token(.note))
            .foregroundStyle(.text(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchWorkoutRow: View {
    let entry: WatchCatalog.Entry
    let isDimmed: Bool

    var body: some View {
        let duration = Duration.milliseconds(entry.totalMilliseconds)
        VStack(alignment: .leading, spacing: .token(spacing: .xxs)) {
            name
                .font(.token(.rowTitle))
                .foregroundStyle(isDimmed ? .text(.secondary) : .text(.primary))
                .lineLimit(2)
            Text(duration.clockText(.hoursMinutesSeconds))
                .font(.token(.rowDetail))
                .foregroundStyle(.text(.secondary))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.token(spacing: .s))
        .background(
            isDimmed ? .surface(.cardInactive) : .surface(.card),
            in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        // VoiceOver reads units in the user's language instead of the clock digits.
        .accessibilityValue(
            Text(duration, format: .units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: .hide(rounded: .down)))
        )
    }

    private var name: Text {
        entry.isUntitled ? Text("watch.workout.untitled", bundle: .module) : Text(verbatim: entry.name)
    }
}
