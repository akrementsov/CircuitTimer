import DesignSystem
import SwiftUI

/// A title and an explanation in place of the list, with the reason the list may be old above them.
struct WatchNoticeView: View {
    let title: Text
    let message: Text?
    var status: WatchRemoteFeature.State.StatusLine?
    var isLoading = false

    var body: some View {
        ScrollView {
            VStack(spacing: .token(spacing: .xs)) {
                if let status {
                    WatchStatusText(status: status)
                }
                if isLoading {
                    ProgressView()
                        .tint(.text(.secondary))
                }
                title
                    .font(.token(.screenTitle))
                    .foregroundStyle(.text(.primary))
                if let message {
                    message
                        .font(.token(.note))
                        .foregroundStyle(.text(.secondary))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Why the list on screen may be old.
struct WatchStatusText: View {
    let status: WatchRemoteFeature.State.StatusLine

    var body: some View {
        text
            .font(.token(.note))
            .foregroundStyle(.text(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: Text {
        switch status {
            case .unlock:
                Text("watch.status.unlock", bundle: .module)
            case .companionMissing:
                Text("watch.status.companionMissing", bundle: .module)
            case let .unreachable(updatedAt):
                Text("watch.status.unreachable \(Self.time(updatedAt))", bundle: .module)
            case let .failed(updatedAt):
                Text("watch.status.failed \(Self.time(updatedAt))", bundle: .module)
            case let .earlierList(updatedAt):
                Text("watch.status.earlierList \(Self.time(updatedAt))", bundle: .module)
        }
    }

    /// The time of a list from today, the date of an older one.
    private static func time(_ date: Date) -> Text {
        Calendar.current.isDateInToday(date) ? Text(date, style: .time) : Text(date, style: .date)
    }
}
