import ComposableArchitecture
import DesignSystem
import Purchases
import SwiftUI
import UITestContract

@ViewAction(for: PurchaseFeature.self)
public struct PurchaseView: View {
    @Bindable public var store: StoreOf<PurchaseFeature>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(store: StoreOf<PurchaseFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .token(spacing: .xxl)) {
                    AppLogo()
                    titles
                    if let reason = store.reason, !store.isShowingSuccess {
                        CaptionPlate(Text(reason.textKey, bundle: .module))
                            .accessibilityIdentifier(AccessibilityID.Purchase.reason)
                    }
                    features
                    if keepsPanelToMainAction {
                        secondaryActions
                    }
                }
                .padding(.horizontal, .token(spacing: .l))
            }
            .contentMargins(.vertical, .token(spacing: .xxl), for: .scrollContent)
            .scrollIndicators(.hidden)
            .screenChrome()
            .toolbar { toolbar }
            .bottomActionPanel { actions }
        }
        // A swipe down would leave the payment sheet on its own.
        .interactiveDismissDisabled(store.isBusy)
        .alert($store.scope(\.$destination, action: \.destination).alert)
        .alert($store.scope(\.$destination, action: \.destination).restoreOffer)
        .task { send(.task) }
    }

    @ViewBuilder
    private var titles: some View {
        if store.isShowingSuccess {
            titles(title: "purchase.title.thanks", subtitle: "purchase.subtitle.unlocked")
                .accessibilityIdentifier(AccessibilityID.Purchase.purchased)
        } else {
            titles(title: "purchase.title", subtitle: "purchase.subtitle")
        }
    }

    private func titles(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: .token(spacing: .xs)) {
            Text(title, bundle: .module)
                .font(.token(.sheetTitle))
                .foregroundStyle(.text(.primary))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle, bundle: .module)
                .font(.token(.body))
                .foregroundStyle(.text(.secondary))
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: .token(spacing: .l)) {
            feature("purchase.feature.workouts")
            feature("purchase.feature.iCloud")
            feature("purchase.feature.watch")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.token(spacing: .l))
        .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
    }

    private func feature(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: .token(spacing: .m)) {
            Image(systemName: store.isShowingSuccess ? "checkmark.circle.fill" : "circle.fill")
                .font(.token(store.isShowingSuccess ? .body : .footnote))
                .foregroundStyle(.brand)
                .accessibilityHidden(true)
            Text(key, bundle: .module)
                .font(.token(.body))
                .foregroundStyle(.text(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// At accessibility sizes the panel holding everything would cover most of the screen and the features under it:
    /// it keeps the main button, and the note, Restore and the fine print follow the features instead.
    private var keepsPanelToMainAction: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var actions: some View {
        VStack(spacing: .zero) {
            mainAction
            if !keepsPanelToMainAction {
                if !store.isShowingSuccess {
                    restoreButton
                }
                finePrint
            }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: .zero) {
            if let note {
                CaptionPlate(Text(note, bundle: .module))
                    .padding(.bottom, .token(spacing: .xs))
            }
            if !store.isShowingSuccess {
                restoreButton
            }
            finePrint
        }
    }

    @ViewBuilder
    private var finePrint: some View {
        if store.showsFinePrint {
            Text("purchase.finePrint", bundle: .module)
                .font(.token(.footnote))
                .foregroundStyle(.text(.secondary))
                .multilineTextAlignment(.center)
                .padding(.horizontal, .token(spacing: .l))
                .padding(.bottom, .token(spacing: .xs))
        }
    }

    /// What the main button's state needs said, above the button or, at accessibility sizes, after the features.
    private var note: LocalizedStringKey? {
        if store.isShowingSuccess { return "purchase.note.iCloudNextLaunch" }
        if store.isPending { return "purchase.note.pending" }
        if store.offer == .unavailable { return "purchase.note.unavailable" }
        return nil
    }

    private var panelNote: Text? {
        guard !keepsPanelToMainAction, let note else { return nil }

        return Text(note, bundle: .module)
    }

    @ViewBuilder
    private var mainAction: some View {
        if store.isShowingSuccess {
            BottomActionPanel(
                title: Text("purchase.done", bundle: .module),
                hint: panelNote,
                isEnabled: true
            ) {
                send(.doneTapped)
            }
            .accessibilityIdentifier(AccessibilityID.Purchase.done)
        } else if store.isPending {
            BottomActionPanel(
                title: Text("purchase.pending", bundle: .module),
                hint: panelNote,
                isEnabled: false
            ) {}
            .accessibilityIdentifier(AccessibilityID.Purchase.pending)
        } else {
            switch store.offer {
                case .loading:
                    BottomActionPanel(
                        title: Text("purchase.buy", bundle: .module),
                        isBusy: true,
                        busyLabel: Text("purchase.loadingPrice", bundle: .module),
                        isEnabled: false
                    ) {}
                    .accessibilityIdentifier(AccessibilityID.Purchase.buy)
                case let .loaded(offer):
                    BottomActionPanel(
                        title: Text("purchase.buy.price \(offer.displayPrice)", bundle: .module),
                        isBusy: store.isPurchasing,
                        busyLabel: Text("purchase.purchasing", bundle: .module),
                        isEnabled: !store.isBusy
                    ) {
                        send(.buyTapped)
                    }
                    .accessibilityIdentifier(AccessibilityID.Purchase.buy)
                case .unavailable:
                    BottomActionPanel(
                        title: Text("purchase.retry", bundle: .module),
                        hint: panelNote,
                        isEnabled: !store.isBusy
                    ) {
                        send(.retryTapped)
                    }
                    .accessibilityIdentifier(AccessibilityID.Purchase.retry)
            }
        }
    }

    private var restoreButton: some View {
        Button {
            send(.restoreTapped)
        } label: {
            if store.isRestoring {
                ProgressView()
                    .tint(.text(.secondary))
            } else {
                Text("purchase.restore", bundle: .module)
            }
        }
        .font(.token(.button))
        .foregroundStyle(.text(.secondary))
        // The explicit color would otherwise hide that the button is disabled; its own spinner stays bright.
        .opacity(store.isBusy && !store.isRestoring ? .token(opacity: .disabled) : 1)
        .frame(maxWidth: .infinity, minHeight: .token(size: .row))
        .contentShape(Rectangle())
        .accessibilityLabel(Text(store.isRestoring ? "purchase.restoring" : "purchase.restore", bundle: .module))
        .disabled(store.isBusy)
        .accessibilityIdentifier(AccessibilityID.Purchase.restore)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                send(.closeTapped)
            } label: {
                Label {
                    Text("purchase.close", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
                .labelStyle(.iconOnly)
            }
            .tint(.text(.primary))
            .disabled(store.isBusy)
            .accessibilityIdentifier(AccessibilityID.Purchase.close)
            // Escape from a bar item would otherwise go up to the navigation controller.
            .accessibilityAction(.escape) { send(.closeTapped) }
        }
    }
}

extension PurchaseFeature.Reason {
    fileprivate var textKey: LocalizedStringKey {
        switch self {
            case .workoutLimit: "purchase.reason.workoutLimit"
            case .iCloudSync: "purchase.reason.iCloud"
        }
    }
}

#Preview("Price loaded") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
    })
    .preferredColorScheme(.dark)
}

#Preview("Limit: workouts") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .limit(.workoutLimit))) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
    })
    .preferredColorScheme(.dark)
}

#Preview("Limit: iCloud") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .limit(.iCloudSync))) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
    })
    .preferredColorScheme(.dark)
}

#Preview("Loading the price") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) { $0.status = .free })
        .preferredColorScheme(.dark)
}

#Preview("Purchasing") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
        $0.operation = .purchasing
    })
    .preferredColorScheme(.dark)
}

#Preview("Restoring") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
        $0.operation = .restoring
    })
    .preferredColorScheme(.dark)
}

#Preview("Waiting for approval") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .free
        $0.isPending = true
    })
    .preferredColorScheme(.dark)
}

#Preview("App Store unavailable") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .unavailable
        $0.status = .free
    })
    .preferredColorScheme(.dark)
}

#Preview("Purchased") {
    PurchaseView(store: previewStore(PurchaseFeature.State(entry: .browse)) {
        $0.offer = .loaded(FullVersionOffer(displayPrice: "$0.99"))
        $0.status = .full
        $0.didUnlockHere = true
    })
    .preferredColorScheme(.dark)
}

/// A store that shows `state` as given: `hasStarted` keeps the sheet's first `.task` from loading the price over it.
@MainActor
private func previewStore(
    _ state: PurchaseFeature.State,
    _ configure: (inout PurchaseFeature.State) -> Void
) -> StoreOf<PurchaseFeature> {
    var state = state
    state.hasStarted = true
    configure(&state)
    return Store(initialState: state) {
        PurchaseFeature()
    } withDependencies: {
        $0.purchases = .previewValue
    }
}
