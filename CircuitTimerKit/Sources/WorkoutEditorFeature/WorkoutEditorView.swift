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
        List {
            Section {
                nameRow
                totalTimeRow
            }
            .listSectionSeparator(.hidden)
            stagesCard(.warmUp)
            if store.draft.canPauseAfterWarmUp {
                pauseCard(isOn: $store.draft.pauseAfterWarmUp.sending(\.view.pauseAfterWarmUpChanged)) {
                    Text("editor.pause.afterWarmUp", bundle: .module)
                }
            }
            stagesCard(.training)
            if store.draft.canPauseAfterTraining {
                pauseCard(isOn: $store.draft.pauseAfterTraining.sending(\.view.pauseAfterTrainingChanged)) {
                    Text("editor.pause.afterTraining", bundle: .module)
                }
            }
            stagesCard(.coolDown)
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, .token(spacing: .m), for: .scrollContent)
        // Rows set their own heights; the system minimum would stretch the thin ones.
        .environment(\.defaultMinListRowHeight, .zero)
        // A swiped row is cut at the card's edge, while the content still scrolls under the bars.
        .mask { Rectangle().ignoresSafeArea(edges: .vertical) }
        .padding(.horizontal, .token(spacing: .l))
        .background(.surface(.screen))
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

    private var nameRow: some View {
        TextField(
            text: $store.draft.name.sending(\.view.nameChanged),
            prompt: Text("editor.name.placeholder", bundle: .module).foregroundStyle(.text(.secondary))
        ) {
            Text("editor.name.placeholder", bundle: .module)
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
        .screenRow()
    }

    private var totalTimeRow: some View {
        TitleAndTimeRow(
            title: Text("editor.totalWorkoutTime", bundle: .module),
            duration: store.draft.totalDuration,
            style: .hoursMinutesSeconds,
            font: .headline
        )
        .padding(.vertical, .token(spacing: .xs))
        // The gaps to the cards around it belong to this row: on iOS 26 a tap anywhere in a row
        // with a text field focuses the field, so the name row ends at its card.
        .padding(.vertical, .token(spacing: .m))
        .screenRow()
    }

    private var title: Text {
        switch store.mode {
            case .create: Text("editor.title.new", bundle: .module)
            case .edit: Text("editor.title.edit", bundle: .module)
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
        ToolbarItem(placement: .confirmationAction) {
            Group {
                if store.isSaving {
                    ProgressView()
                } else {
                    Button {
                        send(afterClearingFocus: .saveButtonTapped)
                    } label: {
                        Text("editor.save", bundle: .module)
                    }
                    .disabled(!store.canSave)
                }
            }
            .accessibilityAction(.escape, leave)
        }
    }

    private func stagesCard(_ section: WorkoutSectionKind) -> some View {
        let stages = store.draft[section]
        return Section {
            TitleAndTimeRow(title: sectionTitle(section), duration: store.draft.duration(of: section), style: .adaptive, font: .body)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, .token(spacing: .l))
                .padding(.vertical, .token(spacing: .xl))
                .cardRow(.top)

            if section == .training {
                Stepper(
                    value: $store.draft.trainingRounds.sending(\.view.trainingRoundsChanged),
                    in: 1...WorkoutLimits.maxTrainingRounds
                ) {
                    Text("editor.rounds \(store.draft.trainingRounds)", bundle: .module)
                }
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .padding(.horizontal, .token(spacing: .l))
                .padding(.bottom, .token(spacing: .xs))
                .cardRow(.middle)
            }

            ForEach(stages) { stage in
                StageRow(
                    stage: stage,
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
                .padding(.bottom, .token(spacing: .xs))
                .cardRow(.middle)
                .moveDisabled(focusedField != nil)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // An empty builder leaves the row without a swipe while a field is being edited.
                    if focusedField == nil {
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
                // Rows read only the stages captured above, as the workout list does with its workouts.
                .accessibilityActions {
                    if stages.indexMovableUp(stage.id) != nil {
                        Button {
                            send(.stageMovedUp(section, stage.id))
                        } label: {
                            Text("editor.stage.moveUp", bundle: .module)
                        }
                    }
                    if stages.indexMovableDown(stage.id) != nil {
                        Button {
                            send(.stageMovedDown(section, stage.id))
                        } label: {
                            Text("editor.stage.moveDown", bundle: .module)
                        }
                    }
                }
            }
            .onMove { send(.stagesMoved(section, $0, $1)) }

            Button {
                send(.addStageButtonTapped(section))
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
            .padding(.top, .token(spacing: .m))
            .padding(.bottom, .token(spacing: .xl))
            .cardRow(.bottom)
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

    private func pauseCard(isOn: Binding<Bool>, @ViewBuilder label: () -> Text) -> some View {
        Section {
            Toggle(isOn: isOn) {
                label()
                    .font(.token(.body))
            }
            .tint(.switchOn)
            .foregroundStyle(.text(.primary))
            .accessibilityHint(Text("editor.pause.footer", bundle: .module))
            .padding(.token(spacing: .l))
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

#Preview("Edit") {
    NavigationStack {
        WorkoutEditorView(store: Store(initialState: WorkoutEditorFeature.State(editing: .sample)) { WorkoutEditorFeature() })
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
        WorkoutEditorView(store: Store(initialState: WorkoutEditorFeature.State(editing: workout)) { WorkoutEditorFeature() })
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
