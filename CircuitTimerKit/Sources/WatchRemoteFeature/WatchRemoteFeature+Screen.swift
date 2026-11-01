import Foundation
import WatchLink

extension WatchCatalog.Entry {
    /// A name of only spaces reads as untitled, as on the iPhone; the watch labels it in its own language.
    var isUntitled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension WatchRemoteFeature.State {
    enum Screen: Equatable {
        case update(WatchRemoteFeature.UpdateSide)
        /// The list; `dimmed` when the iPhone could not load a newer one.
        case list(WatchCatalog, dimmed: UnavailableReason?, status: StatusLine?)
        case empty(status: StatusLine?)
        case unavailable(UnavailableReason, status: StatusLine?)
        case notice(Notice)
    }

    /// A screen for a watch without any list.
    enum Notice: Equatable {
        case unlock
        case companionMissing
        case connecting
        case unreachable
        /// The iPhone answered but has no list yet: its app has not loaded one.
        case noCatalog
    }

    /// Why a list on screen may be old.
    enum StatusLine: Equatable {
        case unlock
        case companionMissing
        case unreachable(updatedAt: Date)
        case failed(updatedAt: Date)
        /// A newer iPhone process answered without a list, so nobody vouches for this one now.
        case earlierList(updatedAt: Date)
    }

    var screen: Screen {
        if case let .incompatible(side) = problem {
            return .update(side)
        }
        guard let catalog else { return .notice(notice) }
        let status = statusLine(updatedAt: catalog.updatedAt)
        if let loaded = catalog.lastLoaded, !loaded.entries.isEmpty {
            return .list(loaded, dimmed: catalog.unavailable, status: status)
        }
        if let reason = catalog.unavailable {
            return .unavailable(reason, status: status)
        }
        return .empty(status: status)
    }

    private var notice: Notice {
        if link?.needsUnlock == true {
            return .unlock
        }
        if problem == .companionMissing {
            return .companionMissing
        }
        // A session still activating is connecting, not unreachable.
        guard let link, !link.isActivating, refresh.hasAnswered || refresh.inFlight == nil else { return .connecting }
        if problem != nil || !link.canSend {
            return .unreachable
        }
        return refresh.hasAnswered ? .noCatalog : .connecting
    }

    private func statusLine(updatedAt: Date) -> StatusLine? {
        if link?.needsUnlock == true {
            return .unlock
        }
        switch problem {
            case .companionMissing:
                return .companionMissing
            case .unreachable:
                return .unreachable(updatedAt: updatedAt)
            case .failed:
                return .failed(updatedAt: updatedAt)
            case .incompatible, nil:
                break
        }
        if let link, !link.isActivating, !link.canSend {
            return .unreachable(updatedAt: updatedAt)
        }
        if let processID = order.processID, order.catalogConfirmedBy != processID {
            return .earlierList(updatedAt: updatedAt)
        }
        return nil
    }
}
