import ComposableArchitecture
import DesignSystem
import SwiftUI
import WorkoutDomain
import WorkoutStorage

/// A text field of the editor. Every `TextField` here is bound to one case through `.focused`:
/// leaving or saving waits until the focused field has committed its text, and an unbound field
/// would be read before its last edit arrives.
enum EditorField: Hashable {
    case name
    case stageName(Stage.ID)
}

@ViewAction(for: WorkoutEditorFeature.self)
public struct WorkoutEditorView: View {
    @Bindable public var store: StoreOf<WorkoutEditorFeature>
    @FocusState private var focusedField: EditorField?
    @State private var actionAfterFocusLoss: WorkoutEditorFeature.Action.View?

    public init(store: StoreOf<WorkoutEditorFeature>) {
        self.store = store
    }

    public var body: some View {
        // One list for every phase: the pencil turns the read-only cells into controls and adds the editing rows,
        // and a save turns them back, as the original app's screen did.
        List {
            Section {
                if store.isEditable {
                    nameRow
                }
                totalTimeRow
            }
            .listSectionSeparator(.hidden)
            stagesCard(.warmUp)
            if store.state.showsPause(after: .warmUp) {
                pauseCard(isOn: $store.draft.pauseAfterWarmUp.sending(\.view.pauseAfterWarmUpChanged)) {
                    Text("editor.pause.afterWarmUp", bundle: .module)
                }
            }
            stagesCard(.training)
            if store.state.showsPause(after: .training) {
                pauseCard(isOn: $store.draft.pauseAfterTraining.sending(\.view.pauseAfterTrainingChanged)) {
                    Text("editor.pause.afterTraining", bundle: .module)
                }
            }
            stagesCard(.coolDown)
        }
        .cardList()
        .bottomActionPanel { actionPanel }
        // The panel sits inside `.disabled` on purpose: inert while saving like the rest of the screen;
        // its spinner still shows because the label switches on being busy, not on being enabled.
        .disabled(store.isSaving)
        .accessibilityAction(.escape, leave)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // A system pop removes the screen without asking the reducer and would drop an unsaved draft.
        // Hiding the system back button also turns off the back gestures, so leaving goes only through Back.
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar }
        .onChange(of: focusedField) { _, field in focusChanged(to: field) }
        .alert($store.scope(\.$destination, action: \.destination).saveFailedAlert)
        .confirmationDialog($store.scope(\.$destination, action: \.destination).discardConfirmation)
    }

    @ViewBuilder
    private var actionPanel: some View {
        if store.isEditable {
            BottomActionPanel(
                title: Text("editor.saveWorkout", bundle: .module),
                hint: store.showsSaveHint ? Text("editor.saveHint", bundle: .module) : nil,
                isBusy: store.isSaving,
                busyLabel: Text("editor.saving", bundle: .module),
                isEnabled: store.canSave,
                action: { send(afterClearingFocus: .saveButtonTapped) }
            )
        } else {
            BottomActionPanel(title: Text("editor.startWorkout", bundle: .module), isEnabled: store.canStart) {
                send(.startButtonTapped)
            }
        }
    }

    private var nameRow: some View {
        TextField(
            text: $store.draft.name.sending(\.view.nameChanged),
            prompt: Text("editor.name.placeholder", bundle: .module).foregroundStyle(.text(.secondary))
        ) {
            Text("editor.name", bundle: .module)
        }
        .focused($focusedField, equals: .name)
        .font(.token(.fieldTitle))
        .foregroundStyle(.text(.primary))
        .padding(.horizontal, .token(spacing: .l))
        .frame(minHeight: .token(size: .row))
        .background(
            focusedField == .name ? .surface(.focused) : .surface(.card),
            in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        )
        // The whole card focuses the field, like the legacy field's insets.
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .name }
        .listRowContentInstant()
        .screenRow()
    }

    private var totalTimeRow: some View {
        TitleAndTimeRow(
            title: Text("editor.totalWorkoutTime", bundle: .module),
            duration: store.shownTotalDuration,
            style: .hoursMinutesSeconds,
            font: .headline
        )
        // `xs` around the text plus the `m` gaps to the cards around it. The gaps belong to this row:
        // on iOS 26 a tap anywhere in a row with a text field focuses the field, so the name row ends at its card.
        .padding(.vertical, .token(spacing: .xl))
        .listRowContentInstant()
        .screenRow()
    }

    private var title: Text {
        switch store.phase {
            case .new:
                Text("editor.title.new", bundle: .module)
            case .viewing:
                if store.workout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("editor.title.untitled", bundle: .module)
                } else {
                    Text(verbatim: store.workout.name)
                }
            case .editing:
                Text("editor.title.edit", bundle: .module)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: leave) {
                Label {
                    Text("editor.back", bundle: .module)
                } icon: {
                    Image(systemName: "chevron.backward")
                }
                .labelStyle(.iconOnly)
            }
            // Tint, not a foreground style, so the chevron still dims while saving.
            .tint(.text(.primary))
            .disabled(store.isSaving)
            // Escape from a bar item would otherwise go up to the navigation controller; on every item it means leave.
            .accessibilityAction(.escape, leave)
        }
        if store.phase == .viewing {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    send(.editButtonTapped, animation: WorkoutEditorFeature.phaseChangeAnimation)
                } label: {
                    Label {
                        Text("editor.edit", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                    .labelStyle(.iconOnly)
                }
                .tint(.brand)
            }
        }
    }

    @ViewBuilder
    private func stagesCard(_ section: WorkoutSectionKind) -> some View {
        if store.state.showsSection(section) {
            stagesCardContent(section)
        }
    }

    private func stagesCardContent(_ section: WorkoutSectionKind) -> some View {
        let stages = store.state.shownStages(in: section)
        let isEditable = store.isEditable
        let endsList = section == store.lastShownSection
        return Section {
            TitleAndTimeRow(title: sectionTitle(section), duration: store.state.shownDuration(of: section), style: .adaptive, font: .body)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, .token(spacing: .l))
                .padding(.top, .token(spacing: .xl))
                .padding(.bottom, .token(spacing: .l))
                .listRowContentInstant()
                .cardRow(.top)

            if section == .training {
                // Through the focus-loss path on purpose, like the original app ending editing first: pending text
                // is committed before the rounds change. Its "first request wins" rule holds here too: a second tap
                // while focus is clearing delivers the first request, and a pending Back or Save goes out instead.
                RoundsRow(
                    rounds: store.shownTrainingRounds,
                    range: WorkoutEditorFeature.State.trainingRoundsRange,
                    isEditable: isEditable
                ) {
                    send(afterClearingFocus: .trainingRoundsChanged($0))
                }
                .padding(.horizontal, .token(spacing: .l))
                .padding(.vertical, .token(spacing: .xxs))
                .listRowContentInstant()
                .cardRow(.middle)
            }

            ForEach(stages) { stage in
                StageRow(
                    stage: stage,
                    isEditable: isEditable,
                    isExpanded: store.expandedStageID == stage.id,
                    name: stageNameBinding(stage, in: section),
                    focus: $focusedField,
                    onIntensityTap: { send(.stageIntensityTapped(section, stage.id)) },
                    onDurationTap: { send(.stageDurationTapped(stage.id)) },
                    onDurationChange: { send(.stageDurationChanged(section, stage.id, $0)) }
                )
                // The lifted row is scaled up; drawn as the whole row it would spill over the card's edges.
                .contentShape(.dragPreview, RoundedRectangle(cornerRadius: .token(radius: .s), style: .continuous))
                .padding(.horizontal, .token(spacing: .l))
                // Half of the gap between stages on each side, so a stage sits in the middle of its own row.
                .padding(.vertical, .token(spacing: .xxs))
                .listRowContentInstant()
                .cardRow(.middle)
                .moveDisabled(!isEditable || focusedField != nil)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // An empty builder leaves the row without a swipe while read-only or while a field is being edited.
                    if isEditable, focusedField == nil {
                        Button(role: .destructive) {
                            send(.stageDeleteButtonTapped(section, stage.id))
                        } label: {
                            Label {
                                Text("editor.stage.delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .tint(.danger)
                    }
                }
                // Rows read only the stages captured above: a row that reads the store observes the stages on its own
                // and is redrawn apart from the list while a drag settles, showing the wrong stage.
                .accessibilityActions {
                    if isEditable, focusedField == nil, stages.indexMovableUp(stage.id) != nil {
                        Button {
                            send(.stageMovedUp(section, stage.id))
                        } label: {
                            Text("editor.stage.moveUp", bundle: .module)
                        }
                    }
                    if isEditable, focusedField == nil, stages.indexMovableDown(stage.id) != nil {
                        Button {
                            send(.stageMovedDown(section, stage.id))
                        } label: {
                            Text("editor.stage.moveDown", bundle: .module)
                        }
                    }
                }
            }
            .onMove { send(.stagesMoved(section, $0, $1)) }

            if isEditable {
                Button {
                    send(.addStageButtonTapped(section), animation: .default)
                } label: {
                    Label {
                        Text("editor.addStage", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                            .imageScale(.large)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                // Tint, not a foreground style, so the icon dims when the section is full.
                .tint(.text(.primary))
                .disabled(!store.state.canAddStage(to: section))
                .frame(maxWidth: .infinity)
                .padding(.top, .token(spacing: .l))
                .padding(.bottom, .token(spacing: .xs))
                .listRowContentInstant()
                .cardRow(.middle)
            }

            // The card's bottom inset in both phases: the add button comes and goes above it, so no part of the card's
            // background disappears while the list animates and the screen never shows through.
            Spacer(minLength: .zero)
                .frame(height: .token(spacing: .m))
                .accessibilityHidden(true)
                .listRowContentInstant()
                .cardRow(.bottom, endsList: endsList)
        }
        .listSectionSeparator(.hidden)
    }

    private func sectionTitle(_ section: WorkoutSectionKind) -> Text {
        switch section {
            case .warmUp: Text("editor.section.warmUp", bundle: .module)
            case .training: Text("editor.section.training", bundle: .module)
            case .coolDown: Text("editor.section.coolDown", bundle: .module)
        }
    }

    /// A switch while editing; read-only, only a pause that plays shows, its title centered and no switch, like the
    /// original cell.
    private func pauseCard(isOn: Binding<Bool>, @ViewBuilder label: () -> Text) -> some View {
        let isEditable = store.isEditable
        return Section {
            ZStack {
                // Sizes the card to the switch in both phases, so it keeps its height.
                Toggle(isOn: .constant(false), label: label)
                    .labelsHidden()
                    .hidden()
                    .accessibilityHidden(true)
                HStack(spacing: .token(spacing: .xs)) {
                    label()
                        .font(.token(.body))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: isEditable ? .leading : .center)
                        // The switch carries the title while editing.
                        .accessibilityHidden(isEditable)
                    if isEditable {
                        Toggle(isOn: isOn, label: label)
                            .labelsHidden()
                            .tint(.switchOn)
                            .accessibilityHint(Text("editor.pause.hint", bundle: .module))
                    }
                }
            }
            .foregroundStyle(.text(.primary))
            .padding(.token(spacing: .l))
            .listRowContentInstant()
            .cardRow(.single)
        }
        .listSectionSeparator(.hidden)
    }

    private func leave() {
        send(afterClearingFocus: .backButtonTapped)
    }

    /// Sends `action` once no field is focused, so the reducer sees the text the user last typed.
    /// This lives in the view because only the view sees when a text field commits its last edit.
    /// The first request wins until it is sent: a later tap delivers the pending request, not its own.
    private func send(afterClearingFocus action: WorkoutEditorFeature.Action.View) {
        if let pending = actionAfterFocusLoss {
            // No focus change came to deliver the request; retry instead of leaving the buttons dead.
            if focusedField == nil {
                actionAfterFocusLoss = nil
                send(pending)
            } else {
                focusedField = nil
            }
            return
        }

        if focusedField == nil {
            send(action)
        } else {
            actionAfterFocusLoss = action
            focusedField = nil
        }
    }

    private func focusChanged(to field: EditorField?) {
        guard let action = actionAfterFocusLoss else { return }

        actionAfterFocusLoss = nil
        // Focusing a field again cancels the request instead of leaving under the user's typing.
        if field == nil {
            send(action)
        }
    }

    private func stageNameBinding(_ stage: Stage, in section: WorkoutSectionKind) -> Binding<String> {
        Binding(
            get: { stage.name },
            set: { send(.stageNameChanged(section, stage.id, $0)) }
        )
    }
}

#Preview("Viewing") {
    NavigationStack {
        WorkoutEditorView(store: Store(initialState: WorkoutEditorFeature.State(viewing: .sample)) { WorkoutEditorFeature() })
    }
    .preferredColorScheme(.dark)
}

#Preview("Edit") {
    NavigationStack {
        WorkoutEditorView(store: Store(initialState: editingPreviewState(.sample)) { WorkoutEditorFeature() })
    }
    .preferredColorScheme(.dark)
}

#Preview("Limits") {
    let longStages = (1...WorkoutLimits.maxStagesPerSection).map { index in
        Stage(id: UUID(index), name: "", duration: WorkoutLimits.maxStageDuration, intensity: index.isMultiple(of: 2) ? .rest : .work)
    }
    let workout = Workout(
        id: UUID(0),
        name: "A very long workout name that does not fit",
        training: longStages,
        trainingRounds: WorkoutLimits.maxTrainingRounds,
        coolDown: [Stage(id: UUID(100), name: "", duration: .seconds(30), intensity: .rest)]
    )
    NavigationStack {
        WorkoutEditorView(store: Store(initialState: editingPreviewState(workout)) { WorkoutEditorFeature() })
    }
    .preferredColorScheme(.dark)
}

#Preview("New") {
    NavigationStack {
        WorkoutEditorView(
            store: Store(initialState: WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1))) {
                WorkoutEditorFeature()
            }
        )
    }
    .preferredColorScheme(.dark)
}

private func editingPreviewState(_ workout: Workout) -> WorkoutEditorFeature.State {
    var state = WorkoutEditorFeature.State(viewing: workout)
    state.phase = .editing
    return state
}

private extension View {
    /// A row's content takes a phase change at once, like the original cells, and only the list animates rows
    /// coming and going. Animated inside, an inserted row grows from nothing and the list re-measures it on every
    /// frame, which drags the rows under it for a second or more.
    func listRowContentInstant() -> some View {
        transaction { $0.animation = nil }
    }
}
