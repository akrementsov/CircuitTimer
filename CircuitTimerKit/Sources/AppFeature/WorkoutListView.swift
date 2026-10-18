import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain

/// The saved workouts as cards, like the original app's list: a tap opens one, a swipe uncovers Duplicate and Delete,
/// and a long press lifts a card to move it.
@ViewAction(for: AppFeature.self)
struct WorkoutListView: View {
    let store: StoreOf<AppFeature>
    let workouts: IdentifiedArrayOf<Workout>
    let hiddenRecordCount: Int

    @State private var rowInteraction = RowInteraction<Workout.ID>()

    var body: some View {
        // Read once for all rows: every row reading the interaction itself is tracked on its own, and on iOS 17 a
        // long list redrawn on every frame of a drag stalls in that tracking.
        let swipedID = rowInteraction.swipedID
        let isLifting = rowInteraction.liftedID != nil
        CardScrollView(interaction: rowInteraction, topMargin: .token(spacing: .m)) { _ in
            VStack(spacing: .token(spacing: .m)) {
                ReorderableRows(
                    items: Array(workouts),
                    spacing: .token(spacing: .m),
                    isEnabled: swipedID == nil,
                    canLift: { _ in true },
                    onRowTap: nil,
                    onMove: { send(.workoutsMoved(IndexSet(integer: $0), $1)) },
                    row: { workout, _ in row(workout, isOpen: swipedID == workout.id, isLifting: isLifting) }
                )
                NotificationCleanupNotice(store: store)
                HiddenRecordsNotice(recordCount: hiddenRecordCount)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, .token(spacing: .l))
            // Padding, not a content margin: the scroll geometry counts only the top margin.
            .padding(.bottom, .token(spacing: .m))
        }
        .onChange(of: workouts.ids) { rowInteraction.closeSwipe() }
        .onDisappear { rowInteraction.closeSwipe() }
    }

    /// Rows read only the workouts captured by the list: a row that reads the store observes them on its own and is
    /// redrawn apart from the list while a drag settles, showing the wrong workout.
    private func row(_ workout: Workout, isOpen: Bool, isLifting: Bool) -> some View {
        Button {
            // A push that waits for a pending write leaves the list on screen; the swipe is closed by then.
            rowInteraction.closeSwipe()
            send(.workoutTapped(workout.id))
        } label: {
            WorkoutRow(workout: workout)
        }
        .buttonStyle(.workoutCard)
        // Taps follow the card, not the row with its margins.
        .contentShape(.interaction, .workoutCard)
        .accessibilityLabel(Text(workout.displayName))
        .accessibilityValue(WorkoutRow.spokenDuration(of: workout))
        .accessibilityActions {
            if workouts.indexMovableUp(workout.id) != nil {
                Button {
                    send(.workoutMovedUp(workout.id))
                } label: {
                    Text("workouts.moveUp", bundle: .module)
                }
            }
            if workouts.indexMovableDown(workout.id) != nil {
                Button {
                    send(.workoutMovedDown(workout.id))
                } label: {
                    Text("workouts.moveDown", bundle: .module)
                }
            }
            // VoiceOver offers these last first: Delete, then Duplicate, in the order of the plaques from the edge.
            Button {
                duplicate(workout.id)
            } label: {
                Text("workouts.duplicate", bundle: .module)
            }
            Button {
                delete(workout.id)
            } label: {
                Text("workouts.delete", bundle: .module)
            }
        }
        // A saved workout is gone for good once deleted, so only an explicit tap on the plaque deletes it.
        .swipePlaques(
            isOpen: Binding(
                get: { isOpen },
                set: { rowInteraction.swipeBinding(for: workout.id).wrappedValue = $0 }
            ),
            isEnabled: !isLifting,
            style: .card,
            actions: [
                SwipePlaqueAction(
                    id: "duplicate",
                    role: .secondary,
                    label: Text("workouts.duplicate", bundle: .module),
                    icon: Image(systemName: "plus.square.on.square")
                ) {
                    duplicate(workout.id)
                },
                SwipePlaqueAction(
                    id: "delete",
                    role: .destructive,
                    label: Text("workouts.delete", bundle: .module),
                    icon: Image(systemName: "trash")
                ) {
                    delete(workout.id)
                },
            ]
        )
    }

    private func delete(_ id: Workout.ID) {
        send(.deleteButtonTapped(id), animation: .default)
    }

    private func duplicate(_ id: Workout.ID) {
        send(.duplicateButtonTapped(id), animation: .default)
    }
}

/// How many stored records the list leaves out, under the list or in place of an empty one.
struct HiddenRecordsNotice: View {
    let recordCount: Int

    var body: some View {
        if recordCount > 0 {
            Text("workouts.hidden \(recordCount)", bundle: .module)
                .font(.token(.footnote))
                .foregroundStyle(.text(.secondary))
        }
    }
}

/// The card does not dim while pressed, like the legacy cell: a swipe starts with a press,
/// and the highlight would flash on every swipe.
private struct WorkoutCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private extension ButtonStyle where Self == WorkoutCardButtonStyle {
    static var workoutCard: Self { WorkoutCardButtonStyle() }
}

private extension Shape where Self == RoundedRectangle {
    static var workoutCard: Self {
        RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var minimumTitleWidth: CGFloat = .token(size: .rowTitleMinWidth)

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    inline
                    stacked
                }
            }
        }
        .foregroundStyle(.text(.primary))
        .padding(.token(spacing: .l))
        .frame(minHeight: .token(size: .row))
        .background(.surface(.card), in: .workoutCard)
    }

    private var inline: some View {
        HStack(spacing: .token(spacing: .l)) {
            // The ideal width is capped so a long name truncates instead of pushing the time under it.
            Text(workout.displayName)
                .font(.token(.body))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: minimumTitleWidth, idealWidth: minimumTitleWidth, maxWidth: .infinity, alignment: .leading)
            time
                .fixedSize()
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .xs)) {
            Text(workout.displayName)
                .font(.token(.body))
                .lineLimit(2)
            time
                .lineLimit(1)
                // Four-digit hours at the largest text sizes.
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var time: some View {
        HStack(spacing: .token(spacing: .xs)) {
            Text(workout.totalDuration.clockText(.hoursMinutesSeconds))
                .font(.token(.body))
                .monospacedDigit()
            Image(systemName: "clock")
                .font(.token(.icon))
        }
    }

    /// VoiceOver reads units in the user's language instead of the clock digits.
    static func spokenDuration(of workout: Workout) -> Text {
        Text(
            workout.totalDuration,
            format: .units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: .hide(rounded: .down))
        )
    }
}
