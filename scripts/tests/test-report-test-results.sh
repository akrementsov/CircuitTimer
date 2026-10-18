#!/usr/bin/env bash
# Tests scripts/report-test-results.sh against xcresulttool's JSON. The fixtures are its output for real bundles: a UI
# test that failed twice and one that passed on its retry, a failed parameterized package test, and passed package
# tests. By hand they got special characters in a test name and a message, and an `Arguments → Repetition →
# Test Case Run` chain, which no real bundle had yet; special characters in a target's name are put in by the test.
. "$(dirname "$0")/lib.sh"

fixtures="$root/scripts/tests/fixtures/report"
report="$root/scripts/report-test-results.sh"

# Stands in for `xcrun xcresulttool get test-results tests --path BUNDLE`, which prints BUNDLE/tests.json.
mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3 $4 $5" = "xcresulttool get test-results tests --path" ] || { echo "xcrun stand-in: $*" >&2; exit 64; }
cat "$6/tests.json"
EOF
chmod +x "$work/bin/xcrun"
export PATH="$work/bin:$PATH"

# bundle NAME [FIXTURE]: a result bundle whose tests are the fixture; without one xcresulttool cannot read it.
bundle() {
	mkdir -p "$work/$1.xcresult"
	if [ $# -gt 1 ]; then
		cp "$2" "$work/$1.xcresult/tests.json"
	fi
	echo "$work/$1.xcresult"
}

describe "CI, several bundles"
ui=$(bundle UI "$fixtures/ui-failed-and-retried.json")
package=$(bundle Package "$fixtures/package-parameterized.json")
unreadable=$(bundle Unreadable)
unexpected=$(bundle Unexpected)
echo '{"devices": []}' > "$unexpected/tests.json"
: > "$work/output"
: > "$work/summary"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
	"$report" "$unreadable" "$ui" "$work/Missing.xcresult" "$unexpected" "$package"
expect_status 0
# Messages escape %, CR and LF; titles also : and ,.
expect_in "$work/out" '::error title=CircuitTimerUITests/ProbeUITests/test_50%25%2C then 100%25()::[First Run] failed - Probe failure: 100%25, sure%0Asecond line%0A[Retry 1] failed - Probe failure: 100%25, sure%0Asecond line'
expect_in "$work/out" '::warning title=CircuitTimerUITests/ProbeUITests/test_probe_passesOnRetry()::Passed only on a retry. [First Run] failed - Probe first attempt fails'
expect_in "$work/out" '::error title=AppScenariosTests/ProbeTests/test_probe_parameterized(value%3A)::[2] Expectation failed: value == 1%0Avalue → 2: Probe: 100%25 sure, value: 2'
expect_in "$work/out" '::warning title=AppScenariosTests/ProbeTests/test_probe_retried(value%3A)::Passed only on a retry. [3, First Run, iPhone 17] Expectation failed: value == 4'
expect_equal "$(grep -c '^::error' "$work/out")" 2
expect_in "$work/out" '::warning::Unreadable.xcresult: xcresulttool could not read the result bundle'
expect_in "$work/out" '::warning::Unexpected.xcresult: the result bundle has an unexpected format'
expect_in "$work/out" 'Missing.xcresult: no result bundle; the tests did not start'
expect_equal "$(cat "$work/output")" "$(printf 'flaky=true\nupload=true')"
expect_in "$work/summary" '- UI.xcresult: 1 test(s) passed only on a retry'
expect_in "$work/summary" '- Package.xcresult: 1 test(s) passed only on a retry'
expect_in "$work/summary" '### Slowest tests in UI.xcresult'
expect_in "$work/summary" '| 0.2 | `ProbeUITests/test_50%, then 100%()` |'
expect_in "$work/summary" '### Slowest tests in Package.xcresult'

describe "CI, special characters in the target"
target=$(bundle Target)
jq '(.. | objects | select(.nodeType == "UI test bundle") | .name) = "UITests: 100%, iPhone"' \
	"$fixtures/ui-failed-and-retried.json" > "$target/tests.json"
run env GITHUB_ACTIONS=true "$report" "$target"
expect_status 0
expect_in "$work/out" '::warning title=UITests%3A 100%25%2C iPhone/ProbeUITests/test_probe_passesOnRetry()::Passed only on a retry.'

describe "terminal"
run "$report" "$ui"
expect_status 0
expect_equal "$(sed -n '1,7p' "$work/out")" "ERROR: CircuitTimerUITests/ProbeUITests/test_50%, then 100%()
    [First Run] failed - Probe failure: 100%, sure
    second line
    [Retry 1] failed - Probe failure: 100%, sure
    second line
WARNING: CircuitTimerUITests/ProbeUITests/test_probe_passesOnRetry()
    Passed only on a retry. [First Run] failed - Probe first attempt fails"
expect_not_in "$work/out" '::'

describe "failures without flaky tests"
failed=$(bundle Failed "$fixtures/package-parameterized.json")
jq 'del(.. | objects | select(.name == "test_probe_retried(value:)"))' "$fixtures/package-parameterized.json" \
	> "$failed/tests.json"
: > "$work/output"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" "$report" "$failed"
expect_status 0
expect_equal "$(cat "$work/output")" "$(printf 'flaky=false\nupload=true')"

describe "passed tests"
passed=$(bundle Passed "$fixtures/package-passed.json")
: > "$work/output"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" "$report" "$passed"
expect_status 0
expect_equal "$(cat "$work/output")" "$(printf 'flaky=false\nupload=false')"
expect_not_in "$work/out" '::'

describe "only a bundle that cannot be read"
: > "$work/output"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" "$report" "$unreadable"
expect_status 0
expect_equal "$(cat "$work/output")" "$(printf 'flaky=false\nupload=true')"

describe "only a bundle of an unexpected format"
: > "$work/output"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" "$report" "$unexpected"
expect_status 0
expect_equal "$(cat "$work/output")" "$(printf 'flaky=false\nupload=true')"

describe "slowest tests"
many=$(bundle Many)
jq '.testNodes[0].children[0].children[0].children as $cases
	| .testNodes[0].children[0].children[0].children = [range(25) as $i
		| $cases[0] | .nodeIdentifier = "Slow/test_\($i)()" | .durationInSeconds = $i]' \
	"$fixtures/package-passed.json" > "$many/tests.json"
run "$report" "$many"
expect_status 0
expect_equal "$(grep -c '^| [0-9]' "$work/out")" 20
expect_in "$work/out" '| 24 | `Slow/test_24()` |'
expect_not_in "$work/out" '`Slow/test_4()`'

describe "usage"
run "$report"
expect_status 2

finish
