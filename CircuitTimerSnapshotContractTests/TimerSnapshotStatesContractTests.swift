@testable import AppFeature
@testable import WorkoutTimerFeature

import BackgroundNotifications
import ComposableArchitecture
import Foundation
import SnapshotCapture
import Testing
import WorkoutDomain

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TimerSnapshotStatesContractTests {
    enum Factory: String, CaseIterable, CustomTestStringConvertible {
        case startCountdown, paused, finished, stageList

        var testDescription: String { rawValue }

        func state() -> WorkoutTimerFeature.State {
            let workout = SnapshotFixtures.editorWorkout(language: .english)
            return switch self {
                case .startCountdown: .startCountdown(workout)
                case .paused: .paused(workout)
                case .finished: .finished(workout)
                case .stageList: .stageList(workout)
            }
        }
    }

    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case haptic, baselineCleared, baselineUnderList, inBackground, sceneInactive, preparingCountdown, clockNotStarted, accessDenied

        var testDescription: String { rawValue }

        func apply(to state: inout WorkoutTimerFeature.State) {
            switch self {
                case .haptic: state.haptic = HapticCue(kind: .countdown, revision: 1)
                case .baselineCleared: state.signals.last = nil
                case .baselineUnderList: state.signals.last = SignalMoment(state)
                case .inBackground: state.isInBackground = true
                case .sceneInactive: state.isSceneActive = false
                case .preparingCountdown: state.isPreparingCountdown = true
                case .clockNotStarted: state.clockGeneration = 0
                case .accessDenied:
                    state.notifications.access = NotificationAccess(authorization: .denied, showsAlerts: false, playsSound: false)
            }
        }

        /// The baseline under an open stage list needs the list; every other change applies to the paused screen.
        var factory: Factory { self == .baselineUnderList ? .stageList : .paused }
    }

    @Test
    func test_startCountdown_settled_countsDownFromThreeOverAnIdleRun() {
        let state = build(.startCountdown)
        #expect(state.countdown == WorkoutTimerFeature.Countdown(purpose: .start, remaining: 3))
        #expect(state.snapshot.status == .idle)
        #expect(state.path.isEmpty)
        #expect(state.destination == nil)
    }

    @Test
    func test_paused_settled_holdsBurpeesTwentySecondsIn() {
        let state = build(.paused)
        #expect(state.snapshot.status == .paused)
        #expect(state.snapshot.currentStage?.stageID == UUID(12))
        #expect(state.snapshot.stageElapsed == .seconds(20))
        #expect(state.snapshot.totalElapsed == .seconds(110))
        #expect(state.countdown == nil)
    }

    @Test
    func test_finished_settled_isFinishedWithoutCountdown() {
        let state = build(.finished)
        #expect(state.snapshot.status == .finished)
        #expect(state.countdown == nil)
    }

    @Test
    func test_stageList_settled_isThePausedRunWithTheListPushed() {
        var paused = build(.paused)
        var list = build(.stageList)
        // Stack element ids come from the context that appends, so the path is compared by its elements.
        #expect(Array(list.path) == [.stageList(paused.outline)])
        list.path = StackState()
        paused.signals.last = nil
        #expect(list == paused)
    }

    @Test(arguments: Factory.allCases)
    func test_hasAppearedForSnapshot_factoryState_isTrue(factory: Factory) {
        #expect(build(factory).hasAppearedForSnapshot)
    }

    @Test(arguments: Change.allCases)
    func test_hasAppearedForSnapshot_changedAfterSettling_isFalse(change: Change) {
        var state = build(change.factory)
        change.apply(to: &state)
        #expect(!state.hasAppearedForSnapshot)
    }

    @Test(arguments: Factory.allCases)
    func test_appearance_factoryState_leavesTheScreenUnchanged(factory: Factory) async {
        let state = build(factory)
        let store = TestStore(initialState: state) {
            WorkoutTimerFeature()
        } withDependencies: {
            TimerSnapshotDependencies.prepare(&$0, locale: Locale(identifier: "en"))
        }
        store.exhaustivity = .off
        await store.send(.view(.scenePhaseChanged(.active)))
        await store.send(.view(.task))
        await store.send(.view(.activityTask))
        await store.finish(timeout: .seconds(5))
        #expect(Screen(store.state) == Screen(state))
        #expect(store.state.haptic == nil)
        #expect(store.state.hasAppearedForSnapshot)
    }

    private func build(_ factory: Factory) -> WorkoutTimerFeature.State {
        withDependencies {
            TimerSnapshotDependencies.prepare(&$0, locale: Locale(identifier: "en"))
        } operation: {
            factory.state()
        }
    }
}

/// Everything the timer's views read.
private struct Screen: Equatable {
    let currentCard: WorkoutTimerFeature.State.CurrentCard
    let nextStageName: String?
    let totalLeft: String
    let spokenTotalLeft: String
    let progressSegments: [WorkoutTimerFeature.State.ProgressSegment]
    let playButton: WorkoutTimerFeature.State.PlayButton
    let isPlayEnabled: Bool
    let isNextEnabled: Bool
    let notificationFootnote: String?
    let isLiveActivityFailing: Bool
    let hasRecordFailed: Bool
    let showsAudioFailure: Bool
    let showsVoiceFailure: Bool
    let title: String
    let path: StackState<WorkoutTimerFeature.Path.State>
    let destination: WorkoutTimerFeature.Destination.State?

    init(_ state: WorkoutTimerFeature.State) {
        currentCard = state.currentCard
        nextStageName = state.nextStageName
        totalLeft = state.totalLeft
        spokenTotalLeft = state.spokenTotalLeft
        progressSegments = state.progressSegments
        playButton = state.playButton
        isPlayEnabled = state.isPlayEnabled
        isNextEnabled = state.isNextEnabled
        notificationFootnote = state.notificationFootnote
        isLiveActivityFailing = state.isLiveActivityFailing
        hasRecordFailed = state.hasRecordFailed
        showsAudioFailure = state.showsAudioFailure
        showsVoiceFailure = state.showsVoiceFailure
        title = state.title
        path = state.path
        destination = state.destination
    }
}
