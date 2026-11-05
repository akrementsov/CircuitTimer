/// Whether the iPhone lets the watch app in: the watch app is part of the full version. The iPhone's own decision; the
/// watch learns only what follows from it, `UnavailableReason.locked` in place of the list.
public enum WatchAccess: Equatable, Sendable {
    case granted
    case locked
}
