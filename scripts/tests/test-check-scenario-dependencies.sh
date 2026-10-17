#!/usr/bin/env bash
# Tests scripts/check-scenario-dependencies.sh on a small tree that passes, each case adding one file to it. The script
# finds the repository by its own place, so every case gets a copy of it.
. "$(dirname "$0")/lib.sh"

# tree CASE: the passing tree in $work/CASE.
tree() {
	dir="$work/$1"
	mkdir -p "$dir/scripts" "$dir/CircuitTimerKit/Sources/Probe" "$dir/CircuitTimerKit/Sources/AppScenarios" \
		"$dir/CircuitTimer"
	cp "$root/scripts/check-scenario-dependencies.sh" "$dir/scripts/"
	cat > "$dir/CircuitTimerKit/Sources/Probe/ProbeClient.swift" <<'EOF'
import Dependencies

public struct ProbeClient: Sendable {
    public var run: @Sendable () -> Void
}

extension ProbeClient: DependencyKey {
    public static let liveValue = ProbeClient(run: {})
    public static let previewValue = ProbeClient(run: {})
}

extension DependencyValues {
    public var probe: ProbeClient {
        get { self[ProbeClient.self] }
        set { self[ProbeClient.self] = newValue }
    }
}
EOF
	cat > "$dir/CircuitTimerKit/Sources/Probe/ProbeFeature.swift" <<'EOF'
struct ProbeFeature {
    @Dependency(\.probe) var probe
    @Dependency(\.date.now) var now
    @Dependency(\.context) var context
    @Shared(.appStorage("probe")) var isOn = false
}
EOF
	cat > "$dir/CircuitTimerKit/Sources/AppScenarios/Prepare.swift" <<'EOF'
func prepare(_ dependencies: inout DependencyValues) {
    dependencies.probe = .previewValue
    dependencies.date = .constant(Date(timeIntervalSinceReferenceDate: 0))
    dependencies.defaultAppStorage = .inMemory
}
EOF
	cat > "$dir/CircuitTimer/ProbeApp.swift" <<'EOF'
struct ProbeApp {
    @Dependency(\.probe) var probe
}
EOF
}

# check CASE [PATH]: the tree of CASE, with the Swift source on stdin at PATH, through the script.
check() {
	tree "$1"
	if [ $# -gt 1 ]; then
		cat > "$dir/$2"
	fi
	run "$dir/scripts/check-scenario-dependencies.sh"
}

# failing CASE PATH TEXT: CASE fails with one problem whose message has TEXT; the source is on stdin.
failing() {
	describe "$1"
	check "$1" "$2"
	expect_status 1
	expect_in "$work/out" "$3"
	expect_in "$work/out" "check-scenario-dependencies: 1 problem(s)"
}

passing() {
	describe "$1"
	check "$1" "$2"
	expect_status 0
	expect_equal "$(cat "$work/out")" ""
}

kit=CircuitTimerKit/Sources/Probe

describe "passing tree"
check passing-tree
expect_status 0
expect_equal "$(cat "$work/out")" ""

failing key-without-preview "$kit/Case.swift" "Case.swift:1: a DependencyKey without a previewValue is live in previews" <<'EOF'
enum PlainKey: DependencyKey {
    static let liveValue = 1
}
EOF

failing preview-reads-live "$kit/Case.swift" "Case.swift:3: previewValue reads liveValue" <<'EOF'
enum MirrorKey: DependencyKey {
    static let liveValue = 1
    static let previewValue = liveValue
}
EOF

failing client-not-set "$kit/Case.swift" "DependencyValues.unset is not set in CircuitTimerKit/Sources/AppScenarios" <<'EOF'
extension DependencyValues {
    public var unset: Int {
        get { 0 }
        set {}
    }
}
EOF

failing app-reads-unset-key CircuitTimer/Case.swift "@Dependency(\\.unsetKey) is read but not set" <<'EOF'
struct ProbeScene {
    @Dependency(\.unsetKey) var value
}
EOF

failing lookup-by-type "$kit/Case.swift" "@Dependency(ProbeClient.self) var probe: read dependencies by key path" <<'EOF'
struct ProbeByType {
    @Dependency(ProbeClient.self) var probe
}
EOF

failing file-storage "$kit/Case.swift" ".fileStorage storage is used but defaultFileStorage is not set" <<'EOF'
struct ProbeFile {
    @Shared(.fileStorage(.documentsDirectory)) var count = 0
}
EOF

# A key behind attributes is still a key: without a preview value it fails, with one it passes.
failing attributed-key-without-preview "$kit/Case.swift" "Case.swift:1: a DependencyKey without a previewValue" <<'EOF'
@available(iOS 17, *) public struct AttributedKey: DependencyKey {
    public static let liveValue = 1
}
EOF

failing actor-key-without-preview "$kit/Case.swift" "Case.swift:1: a DependencyKey without a previewValue" <<'EOF'
@MainActor final class IsolatedKey: Sendable, DependencyKey {
    static let liveValue = 1
}
EOF

failing one-line-key-without-preview "$kit/Case.swift" "Case.swift:1: a DependencyKey without a previewValue" <<'EOF'
enum OneLineKey: DependencyKey { static let liveValue = 1 }
EOF

failing one-line-preview-reads-live "$kit/Case.swift" "Case.swift:1: previewValue reads liveValue" <<'EOF'
enum OneLineMirrorKey: DependencyKey { static let liveValue = 1; static let previewValue = liveValue }
EOF

failing preview-named-in-live-value "$kit/Case.swift" "Case.swift:1: previewValue reads liveValue" <<'EOF'
enum ArgumentKey: DependencyKey { static let liveValue = make(previewValue: false); static let previewValue = liveValue }
EOF

passing preview-ended-on-its-line "$kit/Case.swift" <<'EOF'
enum SplitKey: DependencyKey {
    static let previewValue = 2; static let liveValue = make(
        liveValue: true
    )
}
EOF

passing one-line-key-with-preview "$kit/Case.swift" <<'EOF'
enum OneLineKey: DependencyKey { static let liveValue = 1; static let previewValue = 2 }
enum ReversedKey: DependencyKey { static let previewValue = 2; static let liveValue = 1 }
EOF

passing attributed-key-with-preview "$kit/Case.swift" <<'EOF'
@available(iOS 17, *) public struct AttributedKey: DependencyKey {
    public static let liveValue = 1
    public static let previewValue = 2
}
EOF

passing library-defaults "$kit/Case.swift" <<'EOF'
struct ProbeLibrary {
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.preferredLocales) var locales
    @Dependency(\.context) var context
}
EOF

passing live-value-in-comments "$kit/Case.swift" <<'EOF'
enum QuietKey: DependencyKey {
    static let liveValue = 1
    static let previewValue = 2 // not liveValue
    /* liveValue */
}
EOF

passing generic-constraints "$kit/Case.swift" <<'EOF'
struct Cache<K: DependencyKey, V> {
    var keys: [K]
}

struct Pair<A: Collection<Array<Int>>, B: TestDependencyKey, C> {
    var first: A
}
EOF

finish
