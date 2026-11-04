import DesignSystem
import Foundation
import SwiftUI
import WatchLink

/// A selected catalog entry. The root owns the pending request and resolves the entry again on every update.
struct WatchStartView: View {
    let selection: WatchRemoteFeature.State.Selection
    let status: WatchRemoteFeature.StartNote?
    var linkStatus: WatchRemoteFeature.State.StatusLine?
    let isEnabled: Bool
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .token(spacing: .s)) {
                if let linkStatus { WatchStatusText(status: linkStatus) }
                if let entry {
                    name(entry)
                        .font(.token(.screenTitle))
                        .foregroundStyle(.text(.primary))
                    Text(Duration.milliseconds(entry.totalMilliseconds).clockText(.hoursMinutesSeconds))
                        .font(.token(.rowDetail))
                        .foregroundStyle(.text(.secondary))
                    Text("watch.start.onPhone", bundle: .module)
                        .font(.token(.note))
                        .foregroundStyle(.text(.secondary))
                    if case .unconfirmed = selection {
                        Text("watch.start.unconfirmed", bundle: .module)
                            .font(.token(.note))
                            .foregroundStyle(.text(.secondary))
                    }
                    Button(action: onStart) {
                        Text("watch.start.button", bundle: .module)
                            .font(.token(.control))
                            .foregroundStyle(isEnabled ? .text(.primary) : .text(.secondary))
                            .frame(maxWidth: .infinity, minHeight: .token(size: .watchControl))
                            .background(.surface(.card), in: RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .accessibilityHint(Text("watch.start.hint", bundle: .module))
                }
                if let status { WatchStartStatusView(note: status) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(Text("watch.start.title", bundle: .module))
    }

    private var entry: WatchCatalog.Entry? {
        switch selection {
            case let .ready(entry), let .unconfirmed(entry): entry
            case .unavailable, .gone, .changed, .notPlayable: nil
        }
    }

    private func name(_ entry: WatchCatalog.Entry) -> Text {
        entry.isUntitled ? Text("watch.workout.untitled", bundle: .module) : Text(verbatim: entry.name)
    }
}

struct WatchStartStatusView: View {
    let note: WatchRemoteFeature.StartNote

    var body: some View {
        text
            .font(.token(.note))
            .foregroundStyle(.text(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: Text {
        switch note {
            case .sending: Text("watch.start.sending", bundle: .module)
            case .starting: Text("watch.start.starting", bundle: .module)
            case .asksOnPhone: Text("watch.start.asksOnPhone", bundle: .module)
            case .openPhoneApp: Text("watch.start.openPhoneApp", bundle: .module)
            case .busy: Text("watch.start.busy", bundle: .module)
            case .listUnavailable: Text("watch.start.listUnavailable", bundle: .module)
            case .changed: Text("watch.start.changed", bundle: .module)
            case .gone: Text("watch.start.gone", bundle: .module)
            case .notPlayable: Text("watch.start.notPlayable", bundle: .module)
            case .checkPhone: Text("watch.start.checkPhone", bundle: .module)
        }
    }
}

#Preview {
    WatchStartView(
        selection: .ready(WatchCatalog.Entry(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            name: "Morning workout",
            totalMilliseconds: 600_000,
            isPlayable: true,
            scheduleFingerprint: "preview"
        )),
        status: .asksOnPhone,
        isEnabled: false,
        onStart: {}
    )
    .preferredColorScheme(.dark)
}
