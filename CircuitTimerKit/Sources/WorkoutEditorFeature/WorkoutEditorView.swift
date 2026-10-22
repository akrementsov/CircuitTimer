import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import TipKit
import UITestContract
import WorkoutDomain
import WorkoutStorage

/// The editor's selected input: name fields use SwiftUI focus, and native duration fields report editing callbacks.
/// Leaving or saving waits until the selected field commits its text. A row carries its name's case as its scroll `id`.
enum EditorField: Hashable {
    case name
    case stageName(Stage.ID)
    case stageDuration(Stage.ID)
}

@ViewAction(for: WorkoutEditorFeature.self)
public struct WorkoutEditorView: View {
    @Bindable public var store: StoreOf<WorkoutEditorFeature>
    @FocusState private var focusedNameField: EditorField?
    @State private var focusedDurationID: Stage.ID?
    @State private var actionAfterFocusLoss: WorkoutEditorFeature.Action.View?
    @State private var rowInteraction = RowInteraction<Stage.ID>()

    public init(store: StoreOf<WorkoutEditorFeature>) {
        self.store = store
    }

    public var body: some View {
        // One scroll view of cards for every phase: the pencil turns the read-only cells into controls and opens the
        // editing rows inside their cards, and a save turns them back, as the original app's screen did.
        CardScrollView(interaction: rowInteraction, topMargin: .token(spacing: .m)) { proxy in
            content
                .onChange(of: focusedField) { scrollToFocusedField(proxy) }
                .onChange(of: rowInteraction.visibleRect) { scrollToFocusedField(proxy) }
        }
        // As in the original app, a tap anywhere that takes no input lets the keyboard go: the number pad has no key
        // of its own for it. Fields and buttons take their taps first.
        .onTapGesture { focusedField = nil }
        // A style, not a view, under the keyboard too: its rounded top corners would show the black window.
        .background(.surface(.screen))
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
        .onChange(of: focusedField) { oldField, newField in focusChanged(from: oldField, to: newField) }
        .onChange(of: focusedNameField) { _, field in
            if field != nil { focusedDurationID = nil }
        }
        .onChange(of: store.draft) { rowInteraction.closeSwipe() }
        // A phase change moves the cells like a push moves the screen; the tip waits for both to end.
        .task(id: store.phase) { send(.layoutChanged) }
        .alert($store.scope(\.$destination, action: \.destination).saveFailedAlert)
        .alert($store.scope(\.$destination, action: \.destination).saveBlockedAlert)
        .alert($store.scope(\.$destination, action: \.destination).discardConfirmation)
        .alert($store.scope(\.$destination, action: \.destination).deletedElsewhereAlert)
    }

    // Native fields stay outside FocusState. UIKit ends the previous name's focus when one begins editing;
    // clearing that FocusState afterwards would resign the newly selected numeric field.
    private var focusedField: EditorField? {
        get { focusedDurationID.map(EditorField.stageDuration) ?? focusedNameField }
        nonmutating set {
            if case let .stageDuration(id) = newValue {
                focusedDurationID = id
            } else {
                focusedDurationID = nil
                if focusedNameField != newValue { focusedNameField = newValue }
            }
        }
    }

    private var content: some View {
        // Once for all three cards: it compares the whole draft with the original.
        let unsavableStageIDs = store.state.unsavableStageIDs
        return VStack(spacing: .zero) {
            nameRow
            totalTimeRow
            VStack(spacing: .token(spacing: .m)) {
                stagesCard(.warmUp, unsavableStageIDs: unsavableStageIDs)
                if store.state.showsPause(after: .warmUp) {
                    PauseCard(
                        isOn: $store.draft.pauseAfterWarmUp.sending(\.view.pauseAfterWarmUpChanged),
                        isEditable: store.isEditable,
                        label: Text("editor.pause.afterWarmUp", bundle: .module)
                    )
                    .transition(PlaqueReveal())
                }
                stagesCard(.training, unsavableStageIDs: unsavableStageIDs)
                if store.state.showsPause(after: .training) {
                    PauseCard(
                        isOn: $store.draft.pauseAfterTraining.sending(\.view.pauseAfterTrainingChanged),
                        isEditable: store.isEditable,
                        label: Text("editor.pause.afterTraining", bundle: .module)
                    )
                    .transition(PlaqueReveal())
                }
                stagesCard(.coolDown, unsavableStageIDs: unsavableStageIDs)
            }
        }
        .padding(.horizontal, .token(spacing: .l))
    }

    @ViewBuilder
    private var actionPanel: some View {
        if store.isEditable {
            BottomActionPanel(
                title: Text("editor.saveWorkout", bundle: .module),
                isBusy: store.isSaving,
                busyLabel: Text("editor.saving", bundle: .module),
                isEnabled: store.canSave,
                action: { send(afterClearingFocus: .saveButtonTapped) }
            )
            .accessibilityIdentifier(AccessibilityID.Editor.save)
            // A disabled button takes no taps; while Save is dimmed for a reason, a tap on it asks why instead.
            .gesture(
                TapGesture().onEnded { send(afterClearingFocus: .saveBlockedTapped) },
                including: store.saveBlocker != nil ? .all : .subviews
            )
            // VoiceOver's double tap never reaches a disabled button; the reason is read with it instead.
            .accessibilityHint(store.saveBlocker.map { Text($0.messageKey, bundle: .module) } ?? Text(verbatim: ""))
            .overlay { saveTipAnchor }
        } else {
            BottomActionPanel(title: Text("editor.startWorkout", bundle: .module), isEnabled: store.canStart) {
                send(.startButtonTapped)
            }
            .accessibilityIdentifier(AccessibilityID.Editor.start)
        }
    }

    /// The tip shows once, by TipKit's count, and only when it can point at a still Save: not while typing, under
    /// an alert, or before the screen has settled. Before iOS 26 a tip cannot be hidden by a binding, so the anchor
    /// itself comes and goes.
    @ViewBuilder
    private var saveTipAnchor: some View {
        // A request waiting for the focus to clear is about to leave or explain; the tip must not slip in before it.
        if store.showsSaveTip, let blocker = store.saveBlocker, focusedField == nil, actionAfterFocusLoss == nil {
            // After the tip: its anchor takes taps of its own, and the dimmed Save's tap must reach the panel under it.
            Spacer(minLength: .zero)
                .popoverTip(SaveWorkoutTip(blocker: blocker), arrowEdge: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var nameRow: some View {
        let isEditable = store.isEditable
        return LimitedNameField(
            name: store.draft.name,
            prompt: Text("editor.name.placeholder", bundle: .module).foregroundStyle(.text(.secondary)),
            label: Text("editor.name", bundle: .module)
        ) {
            send(.nameChanged($0))
        }
        .focused($focusedNameField, equals: .name)
        .accessibilityIdentifier(AccessibilityID.Editor.name)
        .font(.token(.fieldTitle))
        .foregroundStyle(.text(.primary))
        .disabled(!isEditable)
        .padding(.horizontal, .token(spacing: .l))
        .frame(minHeight: .token(size: .row))
        // Before the background, so the card grows with its corners rounded.
        .phaseCollapsed(!isEditable)
        .background(
            focusedField == .name ? .surface(.focused) : .surface(.card),
            in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        )
        // The whole card focuses the field, like the legacy field's insets.
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .name }
        .id(EditorField.name)
    }

    private var totalTimeRow: some View {
        TitleAndTimeRow(
            title: Text("editor.totalWorkoutTime", bundle: .module),
            duration: store.shownTotalDuration,
            style: .hoursMinutesSeconds,
            font: .headline
        )
        .contentTransition(.identity)
        // `xs` around the text plus the `m` gaps to the cards around it. The gaps belong to this row, so a tap in
        // them focuses nothing.
        .padding(.vertical, .token(spacing: .xl))
    }

    private var title: Text {
        switch store.phase {
            case .new:
                Text("editor.title.new", bundle: .module)
            case .viewing:
                if let name = store.viewingTitle {
                    Text(verbatim: name)
                } else {
                    Text("editor.title.untitled", bundle: .module)
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
            .accessibilityIdentifier(AccessibilityID.Editor.back)
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
    private func stagesCard(_ section: WorkoutSectionKind, unsavableStageIDs: Set<Stage.ID>) -> some View {
        if store.state.showsSection(section) {
            stagesCardContent(section, unsavableStageIDs: unsavableStageIDs)
                .transition(PlaqueReveal())
        }
    }

    private func stagesCardContent(_ section: WorkoutSectionKind, unsavableStageIDs: Set<Stage.ID>) -> some View {
        let stages = store.state.shownStages(in: section)
        let isEditable = store.isEditable
        return EditorCard {
            TitleAndTimeRow(title: sectionTitle(section), duration: store.state.shownDuration(of: section), style: .adaptive, font: .body)
                .contentTransition(.identity)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, .token(spacing: .l))
                .padding(.top, .token(spacing: .xl))
                .padding(.bottom, .token(spacing: .l))

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
            }

            ReorderableRows(
                items: stages,
                spacing: .zero,
                // A pending TextField focus callback can arrive after the row has lifted. It must not disable
                // the recognizer midway through the drag; the lifted row is already disabled.
                isEnabled: store.state.canReorderStages(in: section)
                    && (focusedField == nil || rowInteraction.liftedID != nil) && rowInteraction.swipedID == nil,
                canLift: { _ in true },
                onRowTap: isEditable && Self.focusesWholeRow ? { focusedField = .stageName($0.id) } : nil,
                onMove: { send(.stagesMoved(section, IndexSet(integer: $0), $1)) },
                row: { stageRow($0, at: $1, in: section, stages: stages, isUnsavable: unsavableStageIDs.contains($0.id)) }
            )

            addStageButton(section)
                .phaseCollapsed(!isEditable)

            // The card's bottom inset in both phases.
            Spacer(minLength: .zero)
                .frame(height: .token(spacing: .m))
                .accessibilityHidden(true)
        }
    }

    /// Rows read only the stages captured by the card: a row that reads the store observes the stages on its own
    /// and is redrawn apart from the card while a drag settles, showing the wrong stage.
    private func stageRow(
        _ stage: Stage,
        at index: Int,
        in section: WorkoutSectionKind,
        stages: [Stage],
        isUnsavable: Bool
    ) -> some View {
        let isEditable = store.isEditable
        let offersActions = isEditable && focusedField == nil
        return StageRow(
            stage: stage,
            section: StageSection(section),
            index: index,
            isEditable: isEditable,
            onNameChange: { send(.stageNameChanged(section, stage.id, $0)) },
            focus: $focusedNameField,
            durationFocus: $focusedDurationID,
            durationHint: Self.durationHint(for: stage, isUnsavable: isUnsavable),
            onIntensityTap: { send(.stageIntensityTapped(section, stage.id)) },
            onDurationTextChange: { send(.stageDurationTextChanged(section, stage.id, $0)) }
        )
        .swipePlaques(
            isOpen: rowInteraction.swipeBinding(for: stage.id),
            isEnabled: offersActions && !store.isSaving && rowInteraction.liftedID == nil,
            style: .row,
            actions: [
                SwipePlaqueAction(
                    id: "delete",
                    role: .destructive,
                    label: Text("editor.stage.delete", bundle: .module),
                    icon: Image(systemName: "trash")
                ) {
                    deleteStage(stage.id, in: section)
                },
            ]
        )
        .padding(.horizontal, .token(spacing: .l))
        // Half of the gap between stages on each side, so a stage sits in the middle of its own row.
        .padding(.vertical, .token(spacing: .xxs))
        // The padding takes the row's taps and its long press too.
        .contentShape(Rectangle())
        .accessibilityActions {
            if offersActions, stages.indexMovableUp(stage.id) != nil {
                Button {
                    send(.stageMovedUp(section, stage.id))
                } label: {
                    Text("editor.stage.moveUp", bundle: .module)
                }
            }
            if offersActions, stages.indexMovableDown(stage.id) != nil {
                Button {
                    send(.stageMovedDown(section, stage.id))
                } label: {
                    Text("editor.stage.moveDown", bundle: .module)
                }
            }
            if offersActions {
                Button {
                    deleteStage(stage.id, in: section)
                } label: {
                    Text("editor.stage.delete", bundle: .module)
                }
            }
        }
        .id(EditorField.stageName(stage.id))
    }

    private func addStageButton(_ section: WorkoutSectionKind) -> some View {
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
        .disabled(!store.state.canAddStage(to: section) || !store.isEditable || rowInteraction.liftedID != nil)
        .frame(maxWidth: .infinity)
        .padding(.top, .token(spacing: .l))
        .padding(.bottom, .token(spacing: .xs))
    }

    private func sectionTitle(_ section: WorkoutSectionKind) -> Text {
        switch section {
            case .warmUp: Text("editor.section.warmUp", bundle: .module)
            case .training: Text("editor.section.training", bundle: .module)
            case .coolDown: Text("editor.section.coolDown", bundle: .module)
        }
    }

    private func deleteStage(_ id: Stage.ID, in section: WorkoutSectionKind) {
        withAnimation(.default) {
            rowInteraction.swipedID = nil
            send(.stageDeleteButtonTapped(section, id))
        }
    }

    /// Keeps the focused field above the bottom panel and the keyboard, scrolling as little as it takes.
    private func scrollToFocusedField(_ proxy: ScrollViewProxy) {
        guard let focusedField else { return }

        let rowID = switch focusedField {
            case let .stageDuration(id): EditorField.stageName(id)
            case .name, .stageName: focusedField
        }
        withAnimation { proxy.scrollTo(rowID) }
    }

    /// On iOS 26 a tap anywhere in a row with a text field focuses the field, as a system list row does there.
    private static var focusesWholeRow: Bool {
        if #available(iOS 26, *) {
            true
        } else {
            false
        }
    }

    private func leave() {
        rowInteraction.closeSwipe()
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

    private func focusChanged(from oldField: EditorField?, to field: EditorField?) {
        // Before the pending Back or Save, so a name left with spaces around it is no change to ask about.
        switch oldField {
            case .name: send(.nameFieldLeft)
            case let .stageName(id): send(.stageNameFieldLeft(id))
            case .stageDuration, nil: break
        }
        // The keyboard slides away, and the panel with it.
        if field == nil {
            send(.layoutChanged)
        }
        guard let action = actionAfterFocusLoss else { return }

        actionAfterFocusLoss = nil
        // Focusing a field again cancels the request instead of leaving under the user's typing.
        if field == nil {
            send(action)
        }
    }

    /// What VoiceOver adds to a stage's duration: a changed stage that keeps Save dimmed says so, and one that would
    /// not play says that a save drops it.
    private static func durationHint(for stage: Stage, isUnsavable: Bool) -> Text? {
        if isUnsavable {
            Text("editor.stage.duration.unsavableHint", bundle: .module)
        } else if !WorkoutLimits.isPlayable(stage) {
            Text("editor.stage.skipped", bundle: .module)
        } else {
            nil
        }
    }
}

private extension StageSection {
    init(_ kind: WorkoutSectionKind) {
        switch kind {
            case .warmUp:
                self = .warmUp
            case .training:
                self = .training
            case .coolDown:
                self = .coolDown
        }
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
            store: Store(
                initialState: WorkoutEditorFeature.State(
                    newWorkoutID: UUID(0),
                    warmUpStageID: UUID(1),
                    trainingStageID: UUID(2),
                    coolDownStageID: UUID(3)
                )
            ) {
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
