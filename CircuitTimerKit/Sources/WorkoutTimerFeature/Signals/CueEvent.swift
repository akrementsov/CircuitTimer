enum CueEvent: Sendable {
    case resignedActive
    case becameActive
    case interruptionBegan
    case interruptionEnded
    case routeChanged(Int)
    case mediaServicesReset
    case voicesChanged
}
