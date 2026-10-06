extension Duration {
    /// Truncates to whole milliseconds. Non-positive values become zero and values beyond
    /// `Int64.max` milliseconds saturate, so arbitrary input never traps.
    func flooredToMilliseconds() -> Duration {
        guard self > .zero else { return .zero }

        let (seconds, attoseconds) = components
        guard seconds < Int64.max / 1_000 else { return .milliseconds(Int64.max) }

        return .milliseconds(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
