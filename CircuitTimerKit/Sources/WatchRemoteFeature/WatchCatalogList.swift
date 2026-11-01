import DesignSystem
import SwiftUI
import WatchLink

/// The iPhone's workouts. The rows do nothing yet: Start from the watch comes in CT-9-5.
struct WatchCatalogList: View {
    let catalog: WatchCatalog
    /// Set when the iPhone could not load a newer list; this one is the last it had.
    let dimmed: UnavailableReason?
    let status: WatchRemoteFeature.State.StatusLine?

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                if let dimmed {
                    note(dimmed == .tooLarge
                        ? Text("watch.catalog.tooLarge.note", bundle: .module)
                        : Text("watch.catalog.loadFailed.note", bundle: .module))
                } else if let status {
                    WatchStatusText(status: status)
                }
                ForEach(catalog.entries) { entry in
                    WatchWorkoutRow(entry: entry, isDimmed: dimmed != nil)
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

    /// A name of only spaces reads as untitled, as on the iPhone; the label follows the watch's language.
    private var name: Text {
        entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Text("watch.workout.untitled", bundle: .module)
            : Text(verbatim: entry.name)
    }
}
