#!/usr/bin/env bash
# Tests scripts/report-test-results.sh against xcresulttool's JSON. The fixtures are its output for real bundles: a UI
# test that failed twice and one that passed on its retry, a failed parameterized package test, and passed package
# tests. By hand they got special characters in a test name and a message, and an `Arguments → Repetition →
# Test Case Run` chain, which no real bundle had yet; special characters in a target's name are put in by the test.
# The action log fixture keeps a real log's sections, trimmed to two test processes, with times set by hand.
. "$(dirname "$0")/lib.sh"

fixtures="$root/scripts/tests/fixtures/report"
report="$root/scripts/report-test-results.sh"

# Stands in for `xcrun xcresulttool get test-results tests --path BUNDLE`, which prints BUNDLE/tests.json, and for
# `xcrun xcresulttool get log --path BUNDLE --type action`, which prints BUNDLE/log.json.
mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$*" = "xcresulttool get log --path ${5:-} --type action" ]; then
	cat "$5/log.json"
	exit
fi
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
cp "$fixtures/package-log.json" "$passed/log.json"
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
expect_in "$work/out" 'WARNING: Many.xcresult: xcresulttool could not read the action log'
expect_in "$work/out" 'Without the action log each time includes waiting'
expect_in "$work/out" '| Seconds | Test |'
expect_equal "$(grep -c '^| [0-9]' "$work/out")" 20
expect_in "$work/out" '| 24 | `Slow/test_24()` |'
expect_not_in "$work/out" '`Slow/test_4()`'

# In process 101 test_waits runs 0–4 s, test_works 0–2 s and test_param 1–2 and 3–4.5 s, one run per argument; spans
# 0–1, 1–2, 2–3, 3–4 and 4–4.5 s have 2, 3, 1, 2 and 1 runs going on. test_param's total leaves out the gap between
# its runs. test_instant takes no time. Process 102 runs another test_waits alone, which keeps apart from the first.
describe "own time"
own=$(bundle Own "$fixtures/package-passed.json")
cp "$fixtures/package-log.json" "$own/log.json"
: > "$work/summary"
run env GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$work/summary" "$report" "$own"
expect_status 0
expect_not_in "$work/out" '::warning'
expect_in "$work/summary" '### Slowest tests in Own.xcresult'
expect_in "$work/summary" 'From 6 runs of 5 tests in 2 test processes.'
expect_in "$work/summary" '| Own, s | Waited, s | Total, s | At once | Test |'
expect_equal "$(grep '^| [0-9]' "$work/summary")" '| 2.33 | 1.67 | 4 | 2 | `Slow/test_waits()` in xctest (101) |
| 1.33 | 1.17 | 2.5 | 2 | `Slow/test_param(value:)` |
| 1 | 0 | 1 | 1 | `Slow/test_waits()` in xctest (102) |
| 0.83 | 1.17 | 2 | 3 | `Slow/test_works()` |
| 0 | 0 | 0 | 1 | `Fast/test_instant()` |'

describe "own time, the 20 with the most"
many_runs=$(bundle ManyRuns "$fixtures/package-passed.json")
jq '(.. | objects | select(.title? == "xctest (101)") | .subsections[2].subsections) |= [range(25) as $i
		| .[0] | .startTime += $i * 100 | .duration = $i | .testDetails.testName = "test_\($i)()"]' \
	"$fixtures/package-log.json" > "$many_runs/log.json"
run "$report" "$many_runs"
expect_status 0
expect_equal "$(grep -c '^| [0-9]' "$work/out")" 20
expect_in "$work/out" '| 24 | 0 | 24 | 1 | `Slow/test_24()` |'
expect_not_in "$work/out" '`Slow/test_4()`'

describe "a log without test runs"
no_runs=$(bundle NoRuns "$fixtures/package-passed.json")
echo '{"title": "Test CircuitTimerKit-Package", "subsections": []}' > "$no_runs/log.json"
: > "$work/output"
run env GITHUB_ACTIONS=true GITHUB_OUTPUT="$work/output" "$report" "$no_runs"
expect_status 0
expect_in "$work/out" '::warning::NoRuns.xcresult: the action log has no test runs'
expect_in "$work/out" '| Seconds | Test |'
expect_in "$work/out" '`ScenarioStorageTests/test_save_concurrentNewWorkouts_keepsEveryOne()` |'
expect_equal "$(cat "$work/output")" "$(printf 'flaky=false\nupload=false')"

describe "a log that is not JSON"
broken=$(bundle Broken "$fixtures/package-passed.json")
echo 'not JSON' > "$broken/log.json"
run env GITHUB_ACTIONS=true "$report" "$broken"
expect_status 0
expect_in "$work/out" '::warning::Broken.xcresult: the action log has an unexpected format'
expect_in "$work/out" '| Seconds | Test |'

describe "usage"
run "$report"
expect_status 2

finish
