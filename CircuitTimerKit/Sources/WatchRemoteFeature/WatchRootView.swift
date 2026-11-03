import ComposableArchitecture
import DesignSystem
import Foundation
import SwiftUI
import WatchLink
import WorkoutActivity
import WorkoutDomain

/// The watch app's root: the iPhone's workouts, or why there are none.
@ViewAction(for: WatchRemoteFeature.self)
public struct WatchRootView: View {
    public let store: StoreOf<WatchRemoteFeature>
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    public init(store: StoreOf<WatchRemoteFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
        }
        .background(.surface(.screen))
        .preferredColorScheme(.dark)
        .task { send(.task) }
        .onChange(of: scenePhase, initial: true) { _, phase in send(.scenePhaseChanged(phase)) }
        .onChange(of: isLuminanceReduced, initial: true) { _, isReduced in send(.luminanceChanged(isReduced: isReduced)) }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            send(.systemClockChanged)
        }
    }

    /// The list's title, or during a workout its name, as the iPhone timer's header shows it; none while a workout too
    /// large to travel runs, whose name the watch does not know.
    private var title: Text {
        switch store.screen {
            case let .run(screen):
                Text(screen.display.title)
            case .notice(.runTooLarge):
                Text(verbatim: "")
            case .update, .list, .empty, .unavailable, .notice:
                Text("watch.list.title", bundle: .module)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.screen {
            case let .update(side):
                WatchNoticeView(
                    title: side == .phone
                        ? Text("watch.link.updatePhone.title", bundle: .module)
                        : Text("watch.link.updateWatch.title", bundle: .module),
                    message: Text("watch.link.update.message", bundle: .module)
                )
            case let .list(catalog, dimmed, status):
                WatchCatalogList(catalog: catalog, dimmed: dimmed, status: status)
            case let .empty(status):
                WatchNoticeView(
                    title: Text("watch.catalog.empty.title", bundle: .module),
                    message: Text("watch.catalog.empty.message", bundle: .module),
                    status: status
                )
            case let .unavailable(reason, status):
                WatchNoticeView(
                    title: reason == .tooLarge
                        ? Text("watch.catalog.tooLarge.title", bundle: .module)
                        : Text("watch.catalog.unavailable.title", bundle: .module),
                    message: reason == .tooLarge
                        ? Text("watch.catalog.tooLarge.message", bundle: .module)
                        : Text("watch.catalog.unavailable.message", bundle: .module),
                    status: status
                )
            case let .notice(notice):
                noticeView(notice)
            case let .run(screen):
                WatchRunView(screen: screen) { send(.controlButtonTapped) }
        }
    }

    @ViewBuilder private func noticeView(_ notice: WatchRemoteFeature.State.Notice) -> some View {
        switch notice {
            case .unlock:
                WatchNoticeView(
                    title: Text("watch.link.unlock.title", bundle: .module),
                    message: Text("watch.link.unlock.message", bundle: .module)
                )
            case .companionMissing:
                WatchNoticeView(
                    title: Text("watch.link.companionMissing.title", bundle: .module),
                    message: Text("watch.link.companionMissing.message", bundle: .module)
                )
            case .connecting:
                WatchNoticeView(title: Text("watch.connecting", bundle: .module), message: nil, isLoading: true)
            case .unreachable:
                WatchNoticeView(
                    title: Text("watch.link.unreachable.title", bundle: .module),
                    message: Text("watch.link.unreachable.message", bundle: .module)
                )
            case .noCatalog:
                WatchNoticeView(
                    title: Text("watch.noCatalog.title", bundle: .module),
                    message: Text("watch.noCatalog.message", bundle: .module)
                )
            case .runTooLarge:
                WatchNoticeView(
                    title: Text("watch.run.tooLarge.title", bundle: .module),
                    message: Text("watch.run.tooLarge.message", bundle: .module)
                )
        }
    }
}

#if DEBUG
extension WatchRemoteFeature.State {
    /// A state as the reducer would reach it, for previews.
    static func preview(
        link: LinkStatus? = LinkStatus(isActivated: true, isReachable: true, needsUnlock: false),
        catalog: WatchRemoteFeature.ShownCatalog? = nil,
        problem: WatchRemoteFeature.LinkProblem? = nil,
        hasAnswered: Bool = true
    ) -> Self {
        var state = Self()
        state.link = link
        state.catalog = catalog
        state.problem = problem
        state.refresh.hasAnswered = hasAnswered
        return state
    }
}

extension Date {
    static let previewDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

extension WatchRemoteFeature.State {
    /// A list an earlier iPhone process published, after a newer process answered that it knows no list yet.
    static var previewEarlierList: Self {
        var state = Self.preview()
        let earlier = PhoneState(
            processID: UUID(uuid: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            sequence: 1,
            publishedAt: .previewDate,
            catalog: .loaded(.preview),
            catalogDigest: "earlier"
        )
        let newer = PhoneState(
            processID: UUID(uuid: (2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            sequence: 0,
            publishedAt: .previewDate,
            catalog: nil,
            catalogDigest: nil
        )
        _ = state.order.receive(earlier, from: .context)
        _ = state.order.receive(newer, from: .reply)
        state.catalog = .init(lastLoaded: .preview, updatedAt: .previewDate)
        return state
    }
}

extension WatchCatalog {
    static let preview = WatchCatalog(entries: [
        .init(id: previewID(1), name: "Morning circuit", totalMilliseconds: 1_260_000, isPlayable: true),
        .init(id: previewID(2), name: " ", totalMilliseconds: 600_000, isPlayable: true),
        .init(id: previewID(3), name: "Tabata", totalMilliseconds: 240_000, isPlayable: true),
    ])

    private static func previewID(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }
}

extension WatchRemoteFeature.State {
    /// A run as the iPhone published it, confirmed unless `confirmed` is false.
    static func previewRun(
        _ phase: WorkoutActivityAttributes.Phase,
        confirmed: Bool = true,
        isLuminanceReduced: Bool = false,
        link: LinkStatus = LinkStatus(isActivated: true, isReachable: true, needsUnlock: false)
    ) -> Self {
        var state = Self.preview(link: link, catalog: .init(lastLoaded: .preview, updatedAt: .previewDate))
        let run = WatchRun(
            owner: UUID(uuid: (9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            attributes: WorkoutActivityAttributes(workoutName: "Morning circuit"),
            content: WorkoutActivityAttributes.ContentState(phase: phase)
        )
        state.run = WatchRemoteFeature.ShownRun(run: run, isLive: true)
        if confirmed {
            state.lease = WatchRemoteFeature.Lease(
                serial: 1,
                sentAt: MonotonicInstant(now: ContinuousClock()),
                openedAt: .distantPast,
                deadline: .distantFuture
            )
        }
        state.isLuminanceReduced = isLuminanceReduced
        state.isSceneActive = true
        return state
    }
}

extension WorkoutActivityAttributes.Phase {
    /// A work stage 20 seconds in, with 25 to go, then a rest.
    static var previewRunning: Self {
        // A preview has no injected clock; its stage counts from the moment it renders.
        // swiftlint:disable:next no_direct_date
        let now = Date.now
        return .running(WorkoutActivityAttributes.Running(
            stage: .init(kind: .work, name: "Burpees"),
            stageStart: now.addingTimeInterval(-20),
            stageEnd: now.addingTimeInterval(25),
            next: .stage(.init(kind: .rest, name: nil), end: now.addingTimeInterval(45))
        ))
    }
}

@MainActor private func previewView(_ state: WatchRemoteFeature.State) -> some View {
    WatchRootView(store: Store(initialState: state) { EmptyReducer() })
        .preferredColorScheme(.dark)
}

#Preview("List") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog.preview, updatedAt: .previewDate)))
}

#Preview("List, iPhone unreachable") {
    previewView(.preview(
        link: LinkStatus(isActivated: true, isReachable: false, needsUnlock: false),
        catalog: .init(lastLoaded: WatchCatalog.preview, updatedAt: .previewDate)
    ))
}

#Preview("List the iPhone could not reload") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog.preview, unavailable: .loadFailed, updatedAt: .previewDate)))
}

#Preview("List cut to fit") {
    let cut = WatchCatalog(entries: WatchCatalog.preview.entries, isTruncated: true)
    return previewView(.preview(catalog: .init(lastLoaded: cut, updatedAt: .previewDate)))
}

#Preview("List, the link failed") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog.preview, updatedAt: .previewDate), problem: .failed))
}

#Preview("Earlier list") {
    previewView(.previewEarlierList)
}

#Preview("No list, the iPhone could not load") {
    previewView(.preview(catalog: .init(unavailable: .loadFailed, updatedAt: .previewDate)))
}

#Preview("No workouts") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog(entries: []), updatedAt: .previewDate)))
}

#Preview("Too large") {
    previewView(.preview(catalog: .init(unavailable: .tooLarge, updatedAt: .previewDate)))
}

#Preview("Connecting") {
    previewView(.preview(link: nil, hasAnswered: false))
}

#Preview("Unlock") {
    previewView(.preview(link: LinkStatus(isActivated: true, isReachable: false, needsUnlock: true)))
}

#Preview("Not connected") {
    previewView(.preview(link: LinkStatus(isActivated: true, isReachable: false, needsUnlock: false)))
}

#Preview("No iPhone app") {
    previewView(.preview(problem: .companionMissing))
}

#Preview("No list on iPhone") {
    previewView(.preview())
}

#Preview("Update the iPhone") {
    previewView(.preview(problem: .incompatible(.phone)))
}

#Preview("Update the watch") {
    previewView(.preview(problem: .incompatible(.watch)))
}

#Preview("Run") {
    previewView(.previewRun(.previewRunning))
}

#Preview("Run, waiting for iPhone") {
    previewView(.previewRun(.previewRunning, confirmed: false))
}

#Preview("Run, iPhone unreachable") {
    previewView(.previewRun(
        .previewRunning,
        confirmed: false,
        link: LinkStatus(isActivated: true, isReachable: false, needsUnlock: false)
    ))
}

#Preview("Run, wrist lowered") {
    previewView(.previewRun(.previewRunning, isLuminanceReduced: true))
}

#Preview("Run, paused") {
    previewView(.previewRun(.paused(.init(stage: .init(kind: .work, name: "Burpees"), remainingMilliseconds: 25_000))))
}

#Preview("Run, get ready") {
    previewView(.previewRun(.getReady(first: .init(stage: .init(kind: .work, name: "Burpees"), remainingMilliseconds: 45_000))))
}

#Preview("Run, Pause waiting for its reply") {
    var state = WatchRemoteFeature.State.previewRun(.previewRunning)
    if let owner = state.run?.run.owner {
        state.command = .init(id: UUID(uuid: (8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), owner: owner, command: .pause)
    }
    return previewView(state)
}

#Preview("Run, a command waiting while its confirmation ran out") {
    var state = WatchRemoteFeature.State.previewRun(.previewRunning, confirmed: false)
    if let owner = state.run?.run.owner {
        state.command = .init(id: UUID(uuid: (8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), owner: owner, command: .pause)
    }
    return previewView(state)
}

#Preview("Run, checking on iPhone without a confirmation") {
    var state = WatchRemoteFeature.State.previewRun(.previewRunning, confirmed: false)
    if let run = state.run?.run {
        state.commandNote = .init(note: .checking, run: run)
    }
    return previewView(state)
}

#Preview("Run, the workout changed on iPhone") {
    var state = WatchRemoteFeature.State.previewRun(
        .paused(.init(stage: .init(kind: .work, name: "Burpees"), remainingMilliseconds: 25_000))
    )
    if let run = state.run?.run {
        state.commandNote = .init(note: .changed, run: run)
    }
    return previewView(state)
}

#Preview("Run, the command failed") {
    var state = WatchRemoteFeature.State.previewRun(.previewRunning)
    if let run = state.run?.run {
        state.commandNote = .init(note: .failed, run: run)
    }
    return previewView(state)
}

#Preview("Run, the stage ended") {
    var state = WatchRemoteFeature.State.previewRun(.previewRunning)
    state.run?.isStageOver = true
    return previewView(state)
}

#Preview("Run, done") {
    previewView(.previewRun(.finished))
}

#Preview("Run too large") {
    var state = WatchRemoteFeature.State.preview()
    state.isRunTooLarge = true
    return previewView(state)
}
#endif
