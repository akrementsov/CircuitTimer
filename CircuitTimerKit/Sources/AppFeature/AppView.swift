import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WorkoutDomain
import WorkoutEditorFeature

@ViewAction(for: AppFeature.self)
public struct AppView: View {
    @Bindable public var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("workouts.title", bundle: .module))
                .toolbar {
                    if store.canEditList {
                        ToolbarItem(placement: .topBarLeading) {
                            EditButton()
                        }
                    }
                    if store.canAddWorkout {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                send(.addButtonTapped)
                            } label: {
                                Label {
                                    Text("workouts.add", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                    }
                }
        }
        .task { send(.task) }
        .sheet(item: $store.scope(\.$destination, action: \.destination).editor) { editorStore in
            NavigationStack {
                WorkoutEditorView(store: editorStore)
            }
        }
        .alert($store.scope(\.$destination, action: \.destination).alert)
    }

    @ViewBuilder
    private var content: some View {
        switch store.workouts {
            case .idle, .loading:
                ProgressView()
            case let .loaded(workouts) where workouts.isEmpty:
                ContentUnavailableView {
                    Label {
                        Text("workouts.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "figure.run")
                    }
                } description: {
                    hiddenRecordsNotice
                } actions: {
                    Button {
                        send(.addButtonTapped)
                    } label: {
                        Text("workouts.empty.create", bundle: .module)
                    }
                }
            case let .loaded(workouts):
                List {
                    Section {
                        ForEach(workouts) { workout in
                            Button {
                                send(.workoutTapped(workout.id))
                            } label: {
                                WorkoutRow(workout: workout)
                            }
                            .accessibilityLabel(WorkoutRow.title(for: workout))
                            .accessibilityValue(WorkoutRow.spokenDuration(of: workout))
                            .swipeActions {
                                rowActions(for: workout.id)
                            }
                            .contextMenu {
                                rowActions(for: workout.id)
                            }
                        }
                        .onMove { send(.workoutsMoved($0, $1)) }
                    } footer: {
                        hiddenRecordsNotice
                    }
                }
            case .failed:
                ContentUnavailableView {
                    Label {
                        Text("workouts.error.title", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } actions: {
                    Button {
                        send(.retryButtonTapped)
                    } label: {
                        Text("workouts.error.retry", bundle: .module)
                    }
                }
        }
    }

    @ViewBuilder
    private func rowActions(for id: Workout.ID) -> some View {
        Button(role: .destructive) {
            send(.deleteButtonTapped(id))
        } label: {
            Label {
                Text("workouts.delete", bundle: .module)
            } icon: {
                Image(systemName: "trash")
            }
        }
        Button {
            send(.duplicateButtonTapped(id))
        } label: {
            Label {
                Text("workouts.duplicate", bundle: .module)
            } icon: {
                Image(systemName: "plus.square.on.square")
            }
        }
    }

    @ViewBuilder
    private var hiddenRecordsNotice: some View {
        if store.hiddenRecordCount > 0 {
            Text("workouts.hidden \(store.hiddenRecordCount)", bundle: .module)
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout

    var body: some View {
        HStack(spacing: .token(spacing: .m)) {
            Self.title(for: workout)
                .font(.token(.headline))
                .foregroundStyle(.text(.primary))
            Spacer()
            HStack(spacing: .token(spacing: .xs)) {
                Text(workout.totalDuration.clockText(.hoursMinutesSeconds))
                    .font(.token(.body))
                    .monospacedDigit()
                Image(systemName: "clock")
                    .font(.token(.icon))
            }
            .foregroundStyle(.text(.primary))
        }
        .padding(.vertical, .token(spacing: .xxs))
    }

    static func title(for workout: Workout) -> Text {
        if workout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("workouts.untitled", bundle: .module)
        } else {
            Text(workout.name)
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

#Preview {
    AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .preferredColorScheme(.dark)
}
