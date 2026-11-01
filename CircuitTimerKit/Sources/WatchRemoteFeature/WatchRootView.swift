import ComposableArchitecture
import DesignSystem
import SwiftUI
import WatchLink

/// The watch app's root: the iPhone's workouts, or why there are none.
@ViewAction(for: WatchRemoteFeature.self)
public struct WatchRootView: View {
    public let store: StoreOf<WatchRemoteFeature>
    @Environment(\.scenePhase) private var scenePhase

    public init(store: StoreOf<WatchRemoteFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("watch.list.title", bundle: .module))
        }
        .background(.surface(.screen))
        .preferredColorScheme(.dark)
        .task { send(.task) }
        .onChange(of: scenePhase, initial: true) { _, phase in send(.scenePhaseChanged(phase)) }
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

@MainActor private func previewView(_ state: WatchRemoteFeature.State) -> some View {
    WatchRootView(store: Store(initialState: state) { EmptyReducer() })
        .preferredColorScheme(.dark)
}

#Preview("List") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog.preview, updatedAt: .distantPast)))
}

#Preview("List, iPhone unreachable") {
    previewView(.preview(
        link: LinkStatus(isActivated: true, isReachable: false, needsUnlock: false),
        catalog: .init(lastLoaded: WatchCatalog.preview, updatedAt: .distantPast)
    ))
}

#Preview("List the iPhone could not reload") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog.preview, unavailable: .loadFailed, updatedAt: .distantPast)))
}

#Preview("No workouts") {
    previewView(.preview(catalog: .init(lastLoaded: WatchCatalog(entries: []), updatedAt: .distantPast)))
}

#Preview("Too large") {
    previewView(.preview(catalog: .init(unavailable: .tooLarge, updatedAt: .distantPast)))
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
#endif
