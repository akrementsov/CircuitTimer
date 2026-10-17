#!/usr/bin/env bash
# Tests scripts/run-tests.sh with a stand-in for xcodebuild that plays one planned outcome per attempt.
. "$(dirname "$0")/lib.sh"

mkdir -p "$work/bin"
# FAKE_PLAN lists one outcome per attempt; the attempt count goes to $FAKE_DIR/attempts. The bundle holds the
# summary that the stand-in for xcrun prints.
cat > "$work/bin/fake-xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -eu
attempt=$(( $(cat "$FAKE_DIR/attempts" 2>/dev/null || echo 0) + 1 ))
echo "$attempt" > "$FAKE_DIR/attempts"
outcome=$(echo "$FAKE_PLAN" | cut -d, -f"$attempt")
while [ "$1" != -resultBundlePath ]; do shift; done
bundle=$2
tests() {
	mkdir -p "$bundle"
	echo "{\"totalTestCount\": $1}" > "$bundle/summary.json"
}
echo "attempt $attempt: $outcome"
case $outcome in
	pass) tests 2; exit 0 ;;
	fail) tests 2; echo "** TEST FAILED **"; exit 65 ;;
	hang) tests 0; echo "The test runner hung before establishing connection."; exit 65 ;;
	hang-without-bundle) echo "Test runner never began executing tests after launching."; exit 65 ;;
	hang-after-tests) tests 2; echo "The test runner hung before establishing connection."; exit 65 ;;
esac
EOF
# Stands in for `xcrun xcresulttool get test-results summary|tests --path BUNDLE`, which prints BUNDLE/<kind>.json.
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3 $5" = "xcresulttool get test-results --path" ] || { echo "xcrun stand-in: $*" >&2; exit 64; }
cat "$6/$4.json"
EOF
chmod +x "$work/bin/fake-xcodebuild" "$work/bin/xcrun"
export PATH="$work/bin:$PATH"

# play CASE PLAN: runs the tests of a fresh case folder through run-tests.sh; the bundle is $dir/results/Run.xcresult.
play() {
	dir="$work/$1"
	mkdir -p "$dir/results"
	run env FAKE_DIR="$dir" FAKE_PLAN="$2" GITHUB_STEP_SUMMARY="$dir/summary" \
		"$root/scripts/run-tests.sh" "$dir/results/Run.xcresult" fake-xcodebuild test -scheme Probe
}

attempts() {
	cat "$dir/attempts" 2>/dev/null || echo 0
}

describe "pass"
play pass pass
expect_status 0
expect_equal "$(attempts)" 1
expect_exists "$dir/results/Run.xcresult/summary.json"
expect_in "$dir/results/Run.log" "attempt 1: pass"

describe "earlier results"
dir="$work/earlier"
mkdir -p "$dir/results/Run.xcresult" "$dir/results/Other.xcresult"
touch "$dir/results/Run.xcresult/stale" "$dir/results/Other.xcresult/kept"
echo "stale run" > "$dir/results/Run.log"
echo "kept run" > "$dir/results/Other.log"
play earlier pass
expect_status 0
expect_missing "$dir/results/Run.xcresult/stale"
expect_not_in "$dir/results/Run.log" "stale run"
expect_exists "$dir/results/Other.xcresult/kept"
expect_in "$dir/results/Other.log" "kept run"

describe "hang, then pass"
play hang-then-pass hang,pass
expect_status 0
expect_equal "$(attempts)" 2
expect_in "$work/out" "::warning::The test runner hung before connecting; retrying Run.xcresult once"
expect_in "$dir/summary" "- The test runner hung before connecting; retrying Run.xcresult once"
expect_equal "$(grep -E '^(attempt|===)' "$dir/results/Run.log")" "attempt 1: hang
=== retry after hung runner ===
attempt 2: pass"

describe "hang without a bundle, then pass"
play hang-without-bundle hang-without-bundle,pass
expect_status 0
expect_equal "$(attempts)" 2

describe "hang twice"
play hang-twice hang,hang
expect_status 65
expect_equal "$(attempts)" 2

describe "hang after tests ran"
play hang-after-tests hang-after-tests
expect_status 65
expect_equal "$(attempts)" 1
expect_not_in "$dir/results/Run.log" "=== retry"

describe "failing test"
play fail fail
expect_status 65
expect_equal "$(attempts)" 1
expect_in "$work/out" "Tests failed; result bundle $dir/results/Run.xcresult, log $dir/results/Run.log"
expect_exists "$dir/results/Run.xcresult"
expect_in "$dir/results/Run.log" "** TEST FAILED **"

describe "usage"
dir="$work/usage"
mkdir -p "$dir"
for arguments in "" "$dir/Run.xcresult" "$dir/Run.result fake-xcodebuild test"; do
	# Word splitting is the point: each string is one argument list.
	run env FAKE_DIR="$dir" FAKE_PLAN=pass "$root/scripts/run-tests.sh" $arguments
	expect_status 2
done
expect_equal "$(attempts)" 0

finish
