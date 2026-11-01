import Dependencies
import Testing

extension TestClock<Duration> {
    /// Returns once a task sleeps on the clock. `advance` wakes only sleeps that are already registered: a task that
    /// starts sleeping after it counts its deadline from the new `now` and never wakes. Yielding a fixed number of
    /// times instead leaves that order to the scheduler, which a loaded CI runner does not keep.
    func waitForSleeper() async {
        while true {
            do {
                // Throws once a sleep is pending; yields to other tasks before it looks.
                try await checkSuspension()
            } catch is SuspensionError {
                return
            } catch {
                Issue.record(error)
                return
            }
        }
    }
}
