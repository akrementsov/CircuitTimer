import ComposableArchitecture
import DesignSystem
import SwiftUI
import WorkoutDomain
import WorkoutStorage

@ViewAction(for: WorkoutEditorFeature.self)
public struct WorkoutEditorView: View {
    @Bindable public var store: StoreOf<WorkoutEditorFeature>

    public init(store: StoreOf<WorkoutEditorFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                TextField(text: $store.draft.name.sending(\.view.nameChanged)) {
                    Text("editor.name.placeholder", bundle: .module)
                }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .interactiveDismissDisabled(store.blocksInteractiveDismiss)
        .alert($store.scope(\.$destination, action: \.destination).saveFailedAlert)
        .confirmationDialog($store.scope(\.$destination, action: \.destination).discardConfirmation)
    }

    private var title: Text {
        switch store.mode {
            case .create: Text("editor.title.new", bundle: .module)
            case .edit: Text("editor.title.edit", bundle: .module)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                send(.cancelButtonTapped)
            } label: {
                Text("editor.cancel", bundle: .module)
            }
            .disabled(store.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if store.isSaving {
                ProgressView()
            } else {
                Button {
                    send(.saveButtonTapped)
                } label: {
                    Text("editor.save", bundle: .module)
                }
                .disabled(!store.canSave)
            }
        }
        // Reordering by drag is not discoverable without an explicit edit mode.
        ToolbarItem(placement: .bottomBar) {
            EditButton()
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
}

#Preview("New") {
    NavigationStack {
        WorkoutEditorView(
            store: Store(initialState: WorkoutEditorFeature.State(newWorkoutID: UUID(0), firstStageID: UUID(1))) {
                WorkoutEditorFeature()
            }
        )
    }
}
