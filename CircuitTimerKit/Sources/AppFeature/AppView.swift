import ComposableArchitecture
import DesignSystem
import Foundation
import SettingsFeature
import SwiftUI
import WorkoutDomain
import WorkoutEditorFeature
import WorkoutTimerFeature

@ViewAction(for: AppFeature.self)
public struct AppView: View {
    @Bindable public var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        // No tint or bar background here: the selected tab takes the accent color, the bar stays the system one.
        TabView(selection: $store.selectedTab.sending(\.view.tabSelected)) {
            workoutsTab
                .tabItem {
                    Label {
                        Text("tabs.workouts", bundle: .module)
                    } icon: {
                        Image(systemName: "figure.run")
                    }
                }
                .tag(AppFeature.RootTab.workouts)
            SettingsView(store: store.scope(\.settings, action: \.settings))
                .tabItem {
                    Label {
                        Text("tabs.settings", bundle: .module)
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                .tag(AppFeature.RootTab.settings)
        }
        .task { send(.task) }
        // Presented over the tab bar, so the write-failure alert shows on either tab.
        .alert($store.scope(\.$destination, action: \.destination).alert)
        // Full screen over the tab bar, with no swipe to dismiss: the timer closes only through its own X.
        .fullScreenCover(item: $store.scope(\.$destination, action: \.destination).timer) { timerStore in
            NavigationStack {
                WorkoutTimerView(store: timerStore)
            }
        }
    }

    private var workoutsTab: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            content
                .navigationTitle(Text("workouts.title", bundle: .module))
                .toolbar {
                    if store.canAddWorkout {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                send(.addButtonTapped)
                            } label: {
                                Label {
                                    Text("workouts.add", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus.app.fill")
                                        .imageScale(.large)
                                }
                            }
                            .tint(.brand)
                        }
                    }
                }
                .screenChrome()
        } destination: { pathStore in
            switch pathStore.case {
                case let .editor(editorStore):
                    WorkoutEditorView(store: editorStore)
                        .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.workouts {
            case .idle, .loading:
                ProgressView()
                    .tint(.text(.secondary))
            case let .loaded(workouts) where workouts.isEmpty:
                VStack(spacing: .token(spacing: .m)) {
                    Text("workouts.empty.title", bundle: .module)
                        .font(.token(.body))
                        .foregroundStyle(.text(.secondary))
                    hiddenRecordsNotice
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, .token(spacing: .l))
            case let .loaded(workouts):
                List {
                    ForEach(workouts) { workout in
                        HStack(spacing: Self.startChipSpacing) {
                            Button {
                                send(.workoutTapped(workout.id))
                            } label: {
                                WorkoutRow(workout: workout)
                            }
                            .buttonStyle(.workoutCard)
                            // Taps follow the card, not the row with its margins.
                            .contentShape(.interaction, .workoutCard)
                            .accessibilityLabel(Text(workout.displayName))
                            .accessibilityValue(WorkoutRow.spokenDuration(of: workout))
                            // Rows read only the list captured above: a row that reads the store observes `workouts`
                            // on its own and is redrawn apart from the list while a drag settles, showing the wrong workout.
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
                            }
                            // TODO: [CT-3-2] An interim way to start a workout until the workout screen's «Start workout».
                            startChip(workout)
                        }
                        // The chip takes the card's height: square at the default text size, taller at large sizes.
                        .fixedSize(horizontal: false, vertical: true)
                        // The chip is dragged with its card, as one preview without the row's margins.
                        .contentShape(.dragPreview, CardAndChipShape(chipWidth: Self.startChipWidth, spacing: Self.startChipSpacing))
                        // A saved workout is gone for good once deleted, so only an explicit tap deletes it.
                        // Duplicate lives here too: a context menu on the row breaks a slow swipe.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                send(.deleteButtonTapped(workout.id))
                            } label: {
                                Label {
                                    Text("workouts.delete", bundle: .module)
                                } icon: {
                                    Image(systemName: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }
                            .tint(.danger)
                            Button {
                                send(.duplicateButtonTapped(workout.id))
                            } label: {
                                Label {
                                    Text("workouts.duplicate", bundle: .module)
                                } icon: {
                                    Image(systemName: "plus.square.on.square")
                                }
                                .labelStyle(.iconOnly)
                            }
                            .tint(.secondaryAction)
                        }
                        .workoutListRow()
                    }
                    .onMove { send(.workoutsMoved($0, $1)) }
                    hiddenRecordsNotice
                        .workoutListRow()
                }
                .listStyle(.plain)
                .listRowSpacing(.token(spacing: .m))
                .contentMargins(.vertical, .token(spacing: .m), for: .scrollContent)
                .scrollIndicators(.hidden)
                // The caption row would otherwise grow to the system minimum; cards set their own.
                .environment(\.defaultMinListRowHeight, .zero)
            case .failed:
                VStack(spacing: .token(spacing: .m)) {
                    Text("workouts.error.title", bundle: .module)
                        .font(.token(.body))
                        .foregroundStyle(.text(.secondary))
                    Button {
                        send(.retryButtonTapped)
                    } label: {
                        Text("workouts.error.retry", bundle: .module)
                            .font(.token(.headline))
                            .foregroundStyle(.brand)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, .token(spacing: .l))
        }
    }

    // The row's layout and its drag preview share these, so the preview always outlines the chip and the card.
    private static let startChipWidth: CGFloat = .token(size: .row)
    private static let startChipSpacing: CGFloat = .token(spacing: .xs)

    /// A chip after the card, as tall as it. A workout with nothing to play keeps a disabled chip, so the cards
    /// stay aligned.
    private func startChip(_ workout: Workout) -> some View {
        Button {
            send(.startButtonTapped(workout.id))
        } label: {
            Image(systemName: "play.fill")
                .font(.token(.body))
                .foregroundStyle(workout.isPlayable ? .text(.primary) : .text(.secondary))
                .frame(width: Self.startChipWidth)
                .frame(maxHeight: .infinity)
                .background(.surface(.card), in: .workoutCard)
        }
        // An explicit style keeps the chip and the card separate buttons: a List row taps every button with the
        // automatic style at once.
        .buttonStyle(.workoutCard)
        .contentShape(.interaction, .workoutCard)
        .disabled(!workout.isPlayable)
        .accessibilityLabel(Text("workouts.start.spoken \(workout.displayName)", bundle: .module))
        // A dead chip only keeps the cards aligned; VoiceOver skips it.
        .accessibilityHidden(!workout.isPlayable)
    }

    @ViewBuilder
    private var hiddenRecordsNotice: some View {
        if store.hiddenRecordCount > 0 {
            Text("workouts.hidden \(store.hiddenRecordCount)", bundle: .module)
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

/// The card and the start chip of a list row, without the gap between them.
private struct CardAndChipShape: Shape {
    let chipWidth: CGFloat
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let chipX = rect.maxX - chipWidth
        let card = CGRect(x: rect.minX, y: rect.minY, width: max(chipX - spacing - rect.minX, .zero), height: rect.height)
        path.addPath(RoundedRectangle.workoutCard.path(in: card))
        path.addPath(RoundedRectangle.workoutCard.path(in: CGRect(x: chipX, y: rect.minY, width: chipWidth, height: rect.height)))
        return path
    }
}

private extension View {
    /// A list row without separator or system background, inset like the legacy cards.
    func workoutListRow() -> some View {
        listRowInsets(EdgeInsets(top: .zero, leading: .token(spacing: .l), bottom: .zero, trailing: .token(spacing: .l)))
            .listRowSeparator(.hidden)
            // A plain list paints rows with the system background, and a clear color is not a token.
            .listRowBackground(Rectangle().fill(.surface(.screen)))
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

@MainActor
private func previewStore(
    _ content: AppFeature.Content,
    hiddenRecordCount: Int = 0,
    selectedTab: AppFeature.RootTab = .workouts
) -> StoreOf<AppFeature> {
    var state = AppFeature.State()
    state.selectedTab = selectedTab
    state.workouts = content
    state.hiddenRecordCount = hiddenRecordCount
    return Store(initialState: state) { AppFeature() }
}

private func previewWorkouts(count: Int) -> IdentifiedArrayOf<Workout> {
    IdentifiedArray(
        uniqueElements: (0..<count).map { index in
            Workout(
                id: UUID(index),
                name: "Workout \(index + 1)",
                training: [Stage(id: UUID(100 + index), name: "", duration: .seconds(75 * (index + 1)), intensity: .work)]
            )
        }
    )
}

#Preview("Live") {
    AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .preferredColorScheme(.dark)
}

#Preview("List") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6))))
        .preferredColorScheme(.dark)
}

#Preview("List with hidden records") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6)), hiddenRecordCount: 2))
        .preferredColorScheme(.dark)
}

#Preview("Empty with hidden records") {
    AppView(store: previewStore(.loaded([]), hiddenRecordCount: 2))
        .preferredColorScheme(.dark)
}

#Preview("Settings tab") {
    AppView(store: previewStore(.loaded(previewWorkouts(count: 6)), selectedTab: .settings))
        .preferredColorScheme(.dark)
}

#Preview("Failed") {
    AppView(store: previewStore(.failed))
        .preferredColorScheme(.dark)
}

#Preview("Long values") {
    let longest = (0..<WorkoutLimits.maxStagesPerSection).map { index in
        Stage(id: UUID(100 + index), name: "", duration: WorkoutLimits.maxStageDuration, intensity: .work)
    }
    let workouts: IdentifiedArrayOf<Workout> = [
        Workout(id: UUID(0), name: "A workout with a name far too long to fit on one line of the list"),
        Workout(id: UUID(1), name: ""),
        Workout(id: UUID(2), name: "Short", training: [Stage(id: UUID(99), name: "", duration: .seconds(75), intensity: .work)]),
        Workout(id: UUID(3), name: "Longest", training: longest, trainingRounds: WorkoutLimits.maxTrainingRounds),
    ]
    AppView(store: previewStore(.loaded(workouts)))
        .preferredColorScheme(.dark)
}
