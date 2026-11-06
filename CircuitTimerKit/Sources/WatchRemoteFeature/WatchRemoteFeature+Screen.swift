import Foundation
import WatchLink
import WorkoutActivity

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
        /// The workout running on the iPhone.
        case run(RunScreen)
        /// The iPhone has no full version, which the watch app is part of.
        case locked(status: StatusLine?)
    }

    /// The running workout as the Live Activity draws it, with its digits only under a live lease.
    struct RunScreen: Equatable {
        let display: WorkoutActivityDisplay
        /// When the lease opened: the screen's timeline starts there, so its first entry is already past.
        let digitsFrom: Date?
        /// When the digits must be gone: the lease's end, or the running stage's end if it comes first. `nil`: no
        /// digits now.
        let digitsUntil: Date?
        /// Why there are no digits, or what became of a command; `nil` with neither, or once the workout is over.
        let note: RunNote?
        /// Where Pause or Resume goes.
        let controlSlot: ControlSlot

        func showsDigits(at date: Date) -> Bool {
            digitsUntil.map { date < $0 } ?? false
        }
    }

    enum RunNote: Equatable {
        case waiting
        case unreachable
        case unlock
        case commandChecking
        case commandChanged
        case commandFailed
    }

    /// The control under the cards. It shows only while the iPhone confirms the time and the stage has not ended: a
    /// command is fenced by the content it was sent from, which must be what the iPhone runs.
    enum ControlSlot: Equatable {
        /// The phase has no control: getting ready, or done.
        case none
        /// The control's place, kept empty so the cards do not move when it comes and goes.
        case reserved
        case button(RunControl)
    }

    struct RunControl: Equatable {
        let command: LiveActivityCommand
        /// False while a command to this timer waits for its reply.
        let isEnabled: Bool
        /// When the button must be gone: the lease's end, or the running stage's end if it comes first. The screen's
        /// timeline hides it then, before any action arrives, and a tap after it sends nothing.
        let until: Date
    }

    /// A screen for a watch without any list.
    enum Notice: Equatable {
        case unlock
        case companionMissing
        case connecting
        case unreachable
        /// The iPhone answered but has no list yet: its app has not loaded one.
        case noCatalog
        /// A workout runs on the iPhone that does not fit in a transfer.
        case runTooLarge
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

    /// The iPhone said the watch app is locked; the list is gone until it says otherwise.
    var isLocked: Bool {
        catalog?.unavailable == .locked
    }

    var selectionStatus: StatusLine? {
        catalog.flatMap { statusLine(updatedAt: $0.updatedAt) }
    }

    var screen: Screen {
        if case let .incompatible(side) = problem {
            return .update(side)
        }
        if isRunTooLarge {
            return .notice(.runTooLarge)
        }
        if let run {
            return .run(runScreen(run))
        }
        guard let catalog else { return .notice(notice) }
        let status = statusLine(updatedAt: catalog.updatedAt)
        if isLocked {
            // No list shows, so a line about an earlier list would mislead.
            if case .earlierList = status { return .locked(status: nil) }
            return .locked(status: status)
        }
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

    private func runScreen(_ shown: WatchRemoteFeature.ShownRun) -> RunScreen {
        let content = shown.run.content
        var digitsUntil: Date?
        if let lease, !isLuminanceReduced, !shown.isStageOver {
            switch content.phase {
                case let .running(running):
                    digitsUntil = min(lease.deadline, running.stageEnd)
                case .paused:
                    // The time left of a paused stage holds still; only the lease vouches for it.
                    digitsUntil = lease.deadline
                case .getReady, .awaitingUser, .finished:
                    break
            }
        }
        let display = WorkoutActivityDisplay(attributes: shown.run.attributes, content: content, isStale: false)
        return RunScreen(
            display: display,
            digitsFrom: digitsUntil == nil ? nil : lease?.openedAt,
            digitsUntil: digitsUntil,
            note: runNote(shown, hasDigits: digitsUntil != nil),
            controlSlot: controlSlot(shown, shownCommand: display.control)
        )
    }

    /// The link's reason comes first, then the command's outcome, then waiting for the iPhone.
    private func runNote(_ shown: WatchRemoteFeature.ShownRun, hasDigits: Bool) -> RunNote? {
        let content = shown.run.content
        if case .finished = content.phase { return nil }
        let isMissingDigits = !hasDigits && !isLuminanceReduced && content.phase.hasDigits
        if isMissingDigits, link?.needsUnlock == true { return .unlock }
        if isMissingDigits, link?.canSend != true || problem == .unreachable { return .unreachable }
        if let shownNote = commandNote, shownNote.run == shown.run {
            switch shownNote.note {
                case .checking:
                    return .commandChecking
                case .changed:
                    return .commandChanged
                case .failed:
                    return .commandFailed
            }
        }
        return isMissingDigits ? .waiting : nil
    }

    private func controlSlot(_ shown: WatchRemoteFeature.ShownRun, shownCommand: LiveActivityCommand?) -> ControlSlot {
        guard let shownCommand else { return .none }
        // The digits' own condition: a confirmation, a stage that has not ended, the wrist raised.
        guard let lease, !shown.isStageOver, !isLuminanceReduced else { return .reserved }
        let until = if case let .running(running) = shown.run.content.phase {
            min(lease.deadline, running.stageEnd)
        } else {
            lease.deadline
        }
        let isWaiting = command?.owner == shown.run.owner
        return .button(RunControl(command: shownCommand, isEnabled: !isWaiting && isSceneActive, until: until))
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

private extension WorkoutActivityAttributes.Phase {
    /// Whether the phase shows a time that needs the iPhone's confirmation.
    var hasDigits: Bool {
        switch self {
            case .running, .paused: true
            case .getReady, .awaitingUser, .finished: false
        }
    }
}
