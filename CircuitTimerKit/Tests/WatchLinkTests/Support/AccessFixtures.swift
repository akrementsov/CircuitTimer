@testable import WatchLink

/// The digest of the locked state, which no list has.
func lockedDigest() throws -> String {
    try WatchCatalog.digest(of: .unavailable(.locked))
}
