@testable import WatchLink

import Foundation
import WorkoutActivity

/// The owner of a timer in the link's tests.
func owner(_ number: Int) -> UUID {
    UUID(link: 100 + number)
}

/// A run of `owner(ownerNumber)` in its running stage; a different `stage` is different content of the same timer.
/// `nameLength` makes the stage's name that long, for a run that needs more room than the reserve.
func makeRun(owner ownerNumber: Int = 1, stage: String = "Burpees", nameLength: Int? = nil) -> WatchRun {
    let start = Date(timeIntervalSince1970: 1_778_000_000)
    return WatchRun(
        owner: owner(ownerNumber),
        attributes: WorkoutActivityAttributes(workoutName: "Morning"),
        content: WorkoutActivityAttributes.ContentState(phase: .running(WorkoutActivityAttributes.Running(
            stage: WorkoutActivityAttributes.Stage(kind: .work, name: nameLength.map { String(repeating: "x", count: $0) } ?? stage),
            stageStart: start,
            stageEnd: start.addingTimeInterval(30),
            next: .finish
        )))
    )
}

extension Sequence where Element == PhoneState {
    /// The catalogs these states carry, in order.
    var catalogs: [CatalogState?] {
        map(\.catalog)
    }
}
