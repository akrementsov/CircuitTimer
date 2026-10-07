import WorkoutDomain

// Stored tokens are part of the schema: renaming a case must not change what is written.

extension WorkoutSectionKind {
    var storageToken: String {
        switch self {
            case .warmUp: "warmUp"
            case .training: "training"
            case .coolDown: "coolDown"
        }
    }

    init?(storageToken: String) {
        switch storageToken {
            case "warmUp": self = .warmUp
            case "training": self = .training
            case "coolDown": self = .coolDown
            default: return nil
        }
    }
}

extension Stage.Intensity {
    var storageToken: String {
        switch self {
            case .work: "work"
            case .rest: "rest"
        }
    }

    init?(storageToken: String) {
        switch storageToken {
            case "work": self = .work
            case "rest": self = .rest
            default: return nil
        }
    }
}
