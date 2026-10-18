import Testing

// MainActor permits interleaving at await; all window owners need one serialized ancestor.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SnapshotTests {}
