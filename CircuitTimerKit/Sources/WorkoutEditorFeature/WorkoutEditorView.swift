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
    // Pushed, the editor shares its navigation stack with the list; its own edit mode keeps the list out of it.
    @State private var editMode: EditMode = .inactive

    public init(store: StoreOf<WorkoutEditorFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                TextField(text: $store.draft.name.sending(\.view.nameChanged)) {
                    Text("editor.name.placeholder", bundle: .module)
                }
                .focused($focusedField, equals: .name)
                LabeledContent {
                    Text(store.draft.totalDuration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                        .monospacedDigit()
                } label: {
                    Text("editor.totalDuration", bundle: .module)
                }
            } footer: {
                if store.showsSaveHint {
                    Text("editor.saveHint", bundle: .module)
                }
            }

            stagesSection(.warmUp)
            if store.draft.canPauseAfterWarmUp {
                pauseSection(isOn: $store.draft.pauseAfterWarmUp.sending(\.view.pauseAfterWarmUpChanged)) {
                    Text("editor.pause.afterWarmUp", bundle: .module)
                }
            }
            stagesSection(.training)
            if store.draft.canPauseAfterTraining {
                pauseSection(isOn: $store.draft.pauseAfterTraining.sending(\.view.pauseAfterTrainingChanged)) {
                    Text("editor.pause.afterTraining", bundle: .module)
                }
            }
            stagesSection(.coolDown)
        }
        .disabled(store.isSaving)
        .accessibilityAction(.escape) { send(afterClearingFocus: .backButtonTapped) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar }
        .onChange(of: focusedField) { _, field in
            guard let action = actionAfterFocusLoss else { return }

            actionAfterFocusLoss = nil
            // Focusing a field again cancels the request instead of leaving under the user's typing.
            if field == nil {
                send(action)
            }
        }
        .alert($store.scope(\.$destination, action: \.destination).saveFailedAlert)
        .confirmationDialog($store.scope(\.$destination, action: \.destination).discardConfirmation)
        .environment(\.editMode, $editMode)
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
            Button {
                send(afterClearingFocus: .backButtonTapped)
            } label: {
                Label {
                    Text("editor.back", bundle: .module)
                } icon: {
                    Image(systemName: "chevron.backward")
                }
                .labelStyle(.iconOnly)
            }
            .foregroundStyle(.text(.primary))
            .disabled(store.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
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
        // Reordering by drag is not discoverable without an explicit edit mode.
        ToolbarItem(placement: .bottomBar) {
            // Toolbar items read the stack's edit mode, not the editor's; bind the button to the form's own.
            EditButton()
                .environment(\.editMode, $editMode)
                .disabled(store.isSaving)
        }
    }

    private func stagesSection(_ section: WorkoutSectionKind) -> some View {
        Section {
            ForEach(store.draft[section]) { stage in
                StageRow(
                    stage: stage,
                    isExpanded: store.expandedStageID == stage.id,
                    name: stageNameBinding(stage, in: section),
                    focus: $focusedField,
                    onIntensityTap: { send(.stageIntensityTapped(section, stage.id)) },
                    onDurationTap: { send(.stageDurationTapped(stage.id)) },
                    onDurationChange: { send(.stageDurationChanged(section, stage.id, $0)) }
                )
            }
            .onDelete { send(.stagesDeleted(section, $0)) }
            .onMove { send(.stagesMoved(section, $0, $1)) }

            if section == .training {
                Stepper(
                    value: $store.draft.trainingRounds.sending(\.view.trainingRoundsChanged),
                    in: 1...WorkoutLimits.maxTrainingRounds
                ) {
                    Text("editor.rounds \(store.draft.trainingRounds)", bundle: .module)
                }
            }

            Button {
                send(.addStageButtonTapped(section))
            } label: {
                Label {
                    Text("editor.addStage", bundle: .module)
                } icon: {
                    Image(systemName: "plus.circle")
                }
            }
            .disabled(!store.state.canAddStage(to: section))
        } header: {
            switch section {
                case .warmUp: Text("editor.section.warmUp", bundle: .module)
                case .training: Text("editor.section.training", bundle: .module)
                case .coolDown: Text("editor.section.coolDown", bundle: .module)
            }
        }
    }

    private func pauseSection(isOn: Binding<Bool>, @ViewBuilder label: () -> Text) -> some View {
        Section {
            Toggle(isOn: isOn, label: label)
        } footer: {
            Text("editor.pause.footer", bundle: .module)
        }
    }

    /// Sends `action` once no field is focused, so the reducer sees the text the user last typed.
    /// The first request wins until it is sent.
    private func send(afterClearingFocus action: WorkoutEditorFeature.Action.View) {
        guard actionAfterFocusLoss == nil else { return }

        if focusedField == nil {
            send(action)
        } else {
            actionAfterFocusLoss = action
            focusedField = nil
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
