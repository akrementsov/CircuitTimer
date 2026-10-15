import ComposableArchitecture
import DesignSystem
import SwiftUI

@ViewAction(for: AppFeature.self)
struct NotificationCleanupNotice: View {
    let store: StoreOf<AppFeature>
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        if store.isNotificationCleanupStalled {
            VStack(alignment: alignment, spacing: .token(spacing: .s)) {
                Text("workouts.notifications.cleanupStalled", bundle: .module)
                    .foregroundStyle(.text(.secondary))
                Button {
                    send(.notificationCleanupRetryTapped)
                } label: {
                    Text("workouts.notifications.cleanupRetry", bundle: .module)
                        .foregroundStyle(.brand)
                }
            }
            .font(.token(.footnote))
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        }
    }
}
