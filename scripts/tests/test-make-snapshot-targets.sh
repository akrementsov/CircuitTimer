#!/usr/bin/env bash
# Test the real Makefile's process boundaries and recording guards without starting Xcode or changing references.
. "$(dirname "$0")/lib.sh"

# make's abspath removes repeated separators; TMPDIR commonly ends with a slash on macOS.
work=$(printf '%s' "$work" | sed 's@//*@/@g')

repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/CircuitTimerSnapshotKit" "$work/bin" "$work/trace"
cp "$root/Makefile" "$repo/"
cat > "$repo/scripts/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'bundle:%s\n' "$1" >> "$TRACE/calls"
mkdir -p "$1"
shift
"$@"
EOF
cat > "$repo/scripts/check-snapshot-run.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --select ]; then
	if [ "${FAIL_SELECTION:-}" = 1 ]; then echo 'unknown snapshot test' >&2; exit 1; fi
	printf 'CircuitTimerSnapshotTests/SnapshotTests/ProbeSnapshotTests/%s(textSize:)\n' "$2"
	exit
fi
printf 'check:%s\n' "$*" >> "$TRACE/calls"
if [ "${1:-}" != --same-cases ] && [ "${FAIL_PAIR:-}" = "$1-$2-$3" ]; then exit 1; fi
EOF
cat > "$work/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = -version ]; then
	printf 'Xcode 27.1\nBuild version 18B1\n'
	exit
fi
if [ "$1" = build-for-testing ]; then
	printf '%s\n' "$@" > "$TRACE/build.args"
	exit
fi
if [ -z "${TEST_RUNNER_SNAPSHOT_TESTING_RECORD:-}" ]; then exit 0; fi
printf '%s\n' "$@" > "$TRACE/${TEST_RUNNER_SNAPSHOT_TESTING_RECORD}-$TEST_RUNNER_SNAPSHOT_TEXT_SIZE-$(basename "$TEST_RUNNER_SNAPSHOT_ARTIFACTS").args"
printf 'environment:%s %s %s\n' "$TEST_RUNNER_SNAPSHOT_TESTING_RECORD" "$TEST_RUNNER_SNAPSHOT_TEXT_SIZE" "$TEST_RUNNER_SNAPSHOT_ARTIFACTS" >> "$TRACE/calls"
# The recipe must remove old files before it starts the next test process.
if [ -e "$TEST_RUNNER_SNAPSHOT_ARTIFACTS/stale" ]; then exit 99; fi
if [ "${FAIL_XCODE:-}" = "$TEST_RUNNER_SNAPSHOT_TESTING_RECORD-$TEST_RUNNER_SNAPSHOT_TEXT_SIZE" ]; then exit 65; fi
EOF
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${SUMMARY_READ_FAIL:-}" = 1 ]; then exit 1; fi
while [ "$#" -gt 0 ]; do
	if [ "$1" = --path ]; then
		shift
		printf 'summary:%s\n' "$1" >> "$TRACE/calls"
		[ -d "$1" ] || { echo "Missing result bundle: $1" >&2; exit 1; }
		break
	fi
	shift
done
if [ -n "${CONTRACT_SUMMARY:-}" ]; then
	printf '%s\n' "$CONTRACT_SUMMARY"
else
	printf '{"passedTests":1,"skippedTests":0,"failedTests":0}\n'
fi
EOF
cat > "$work/bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1 ${2:-}" in
	'status --porcelain') if [ "${DIRTY_REFERENCES:-}" = 1 ]; then echo ' M reference.png'; fi ;;
	'status --short') echo final-status >> "$TRACE/calls" ;;
	'ls-files --others') echo final-new-references >> "$TRACE/calls" ;;
	*) exit 64 ;;
esac
EOF
chmod +x "$repo/scripts/"*.sh "$work/bin/"*
export PATH="$work/bin:$PATH" TRACE="$work/trace"
reference='platform=iOS Simulator,name=iPhone 17,OS=27.0'
second='platform=iOS Simulator,name=iPhone 17 #2,OS=27.0'
third='platform=iOS Simulator,name=iPhone 17 #3,OS=27.0'

reset_trace() { rm -rf "$TRACE"; mkdir -p "$TRACE"; : > "$TRACE/calls"; }
snapshot_make() {
	run make -s -C "$repo" "$1" DESTINATION="$reference" TEST_RESULTS="$work/results" \
		DERIVED_DATA="$work/dd" SOURCE_PACKAGES="$work/sp" "${@:2}"
}

describe 'S036/S042/S115/S116: four isolated processes, shared build arguments, clean artifacts and version output'
reset_trace
for language in en ru; do
	for size in large ax5; do
		mkdir -p "$work/results/Snapshots-iPhone-17-27.0-$language-$size-artifacts"
		: > "$work/results/Snapshots-iPhone-17-27.0-$language-$size-artifacts/stale"
	done
done
snapshot_make build-snapshots
expect_status 0
GITHUB_STEP_SUMMARY="$work/summary" snapshot_make test-snapshots
expect_status 0
expect_in "$work/out" 'Xcode 27.1'
expect_in "$work/summary" 'Build version 18B1'
expect_equal "$(grep -c '^bundle:' "$TRACE/calls")" 4
expect_equal "$(grep -c '^check:never' "$TRACE/calls")" 4
expect_equal "$(grep -c '^check:--same-cases' "$TRACE/calls")" 1
for language in en ru; do
	case "$language" in en) region=US ;; ru) region=RU ;; esac
	for size in large ax5; do
		case "$size" in large) category=UICTContentSizeCategoryL ;; ax5) category=UICTContentSizeCategoryAccessibilityXXXL ;; esac
		base="$work/results/Snapshots-iPhone-17-27.0-$language-$size"
		arguments="$TRACE/never-$size-$(basename "$base")-artifacts.args"
		expect_exists "$arguments"
		expect_equal "$(head -1 "$arguments")" test
		expect_equal "$(sed 1d "$TRACE/build.args" | LC_ALL=C sort | LC_ALL=C comm -23 - <(LC_ALL=C sort "$arguments"))" ''
		expect_in "$arguments" "SNAPSHOT_CONTENT_SIZE_CATEGORY=$category"
		expect_equal "$(grep -A1 -e '-testLanguage' "$arguments")" "-testLanguage
$language"
		expect_equal "$(grep -A1 -e '-testRegion' "$arguments")" "-testRegion
$region"
		expect_equal "$(grep -A1 -e '-parallel-testing-enabled' "$arguments")" '-parallel-testing-enabled
NO'
		expect_in "$TRACE/calls" "environment:never $size $base-artifacts"
		expect_in "$TRACE/calls" "bundle:$base.xcresult"
	done
done

describe 'S039: complete recording precedes comparison, then status and new references'
reset_trace
snapshot_make record-snapshots
expect_status 0
expect_equal "$(grep -c '^bundle:' "$TRACE/calls")" 8
expect_equal "$(grep '^environment:' "$TRACE/calls" | sed 's/^environment:\([^ ]*\).*/\1/' | uniq)" 'failed
never'
expect_equal "$(tail -2 "$TRACE/calls")" 'final-status
final-new-references'
expect_equal "$(grep -c '^bundle:.*-record.xcresult$' "$TRACE/calls")" 4

describe 'S103/S124: allowed simulators use separate run paths'
for destination in "$second" "$third"; do
	reset_trace
	snapshot_make test-snapshots DESTINATION="$destination"
	expect_status 0
	case "$destination" in "$second") run_name=iPhone-17-2-27.0 ;; *) run_name=iPhone-17-3-27.0 ;; esac
	expect_in "$TRACE/calls" "bundle:$work/results/Snapshots-$run_name-en-large.xcresult"
	expect_in "$TRACE/calls" "$work/results/Snapshots-$run_name-en-large-artifacts"
	expect_in "$TRACE/never-large-Snapshots-$run_name-en-large-artifacts.args" "$work/dd/Snapshots-$run_name"
done
reset_trace
snapshot_make test-snapshots DESTINATION='platform=iOS Simulator,name=iPhone 15,OS=17.5'
expect_status 2
expect_in "$work/out" 'comparisons require'
expect_equal "$(cat "$TRACE/calls")" ''

describe 'S104: empty, unsupported and duplicate languages fail before xcodebuild'
for languages in '' 'de' 'en en'; do
	reset_trace
	snapshot_make test-snapshots SNAPSHOT_LANGUAGES="$languages"
	expect_status 2
	expect_equal "$(cat "$TRACE/calls")" ''
done

describe 'S105: selection and repetition flags are rejected by both entry points'
for target in test-snapshots record-snapshots; do
	for variable in TEST_FLAGS XCODEBUILD_FLAGS; do
		for flag in '-only-testing:Probe' '-skip-testing:Probe' '-test-iterations 2' '-retry-tests-on-failure' '-run-tests-until-failure' \
			'-only-test-configuration Probe' '-skip-test-configuration Probe' '-testPlan Probe' '-test-repetition-relaunch-enabled YES'; do
			reset_trace
			snapshot_make "$target" "$variable=$flag"
			expect_status 2
			expect_in "$work/out" 'would select or repeat cases'
			expect_equal "$(cat "$TRACE/calls")" ''
		done
	done
done

describe 'S106: recording guards'
reset_trace
CI=true snapshot_make record-snapshots
expect_status 2
expect_in "$work/out" 'recording is local only'
expect_equal "$(cat "$TRACE/calls")" ''
reset_trace
snapshot_make record-snapshots DESTINATION="$second"
expect_status 2
expect_in "$work/out" 'references require'
expect_equal "$(cat "$TRACE/calls")" ''
reset_trace
DIRTY_REFERENCES=1 snapshot_make record-snapshots
expect_status 2
expect_in "$work/out" 'review and commit reference changes'
expect_equal "$(cat "$TRACE/calls")" ''

describe 'S108/S109: failed pairs do not truncate the stage or compare incomplete matrices'
for pair in never-en-large never-en-ax5 never-ru-large never-ru-ax5; do
	reset_trace
	FAIL_PAIR="$pair" snapshot_make test-snapshots
	expect_status 2
	expect_equal "$(grep -c '^bundle:' "$TRACE/calls")" 4
	expect_not_in "$TRACE/calls" 'check:--same-cases'
done
reset_trace
FAIL_XCODE=never-large snapshot_make test-snapshots
# The checker receives the failed xcodebuild status; its own verdict decides the stage result.
expect_status 0
expect_in "$TRACE/calls" 'check:never en large 65'
reset_trace
snapshot_make test-snapshots SNAPSHOT_LANGUAGES=en
expect_status 0
expect_equal "$(grep -c '^bundle:' "$TRACE/calls")" 2
expect_not_in "$TRACE/calls" 'check:--same-cases'

describe 'G10: failed record stage completes its pairs but never starts compare or final listing'
reset_trace
FAIL_PAIR=failed-en-large snapshot_make record-snapshots
expect_status 2
expect_equal "$(grep -c '^bundle:' "$TRACE/calls")" 4
expect_not_in "$TRACE/calls" 'check:never'
expect_not_in "$TRACE/calls" final-status
expect_not_in "$TRACE/calls" final-new-references

describe 'S075: dedicated language runs must execute one passing case, never only skip'
for target in test-snapshot-kit test-snapshot-contracts; do
	reset_trace
	snapshot_make "$target"
	expect_status 0
	for summary in '{"passedTests":0,"skippedTests":1,"failedTests":0}' '{"passedTests":0,"skippedTests":0,"failedTests":0}' '{"passedTests":0,"skippedTests":0,"failedTests":1}' invalid; do
		reset_trace
		CONTRACT_SUMMARY="$summary" snapshot_make "$target"
		expect_status 2
	done
	reset_trace
	SUMMARY_READ_FAIL=1 snapshot_make "$target"
	expect_status 2
done

describe 'PR30: result overrides resolve from the checkout and preserve spaces'
# make's CURDIR uses the physical path; macOS TMPDIR may go through the /var symlink.
physical_repo="$(cd "$repo" && pwd -P)"
for results in relative-results 'relative results' "$work/absolute results"; do
	case "$results" in /*) expected_results="$results" ;; *) expected_results="$physical_repo/$results" ;; esac
	for target in test-snapshot-kit test-snapshot-contracts; do
		reset_trace
		snapshot_make "$target" TEST_RESULTS="$results"
		expect_status 0
		case "$target" in
			test-snapshot-kit) suite=SnapshotKit; language=ru ;;
			*) suite=SnapshotContracts; language=de ;;
		esac
		expect_in "$TRACE/calls" "bundle:$expected_results/$suite-iPhone-17-27.0.xcresult"
		expect_in "$TRACE/calls" "bundle:$expected_results/$suite-iPhone-17-27.0-$language.xcresult"
		expect_in "$TRACE/calls" "summary:$expected_results/$suite-iPhone-17-27.0-$language.xcresult"
	done
done

describe 'S040/S107: lockfile union, shared pins and SnapshotTesting ownership'
kit="$work/kit.json"; snapshots="$work/snapshots.json"; project="$work/project.json"
reset_pins() {
	printf '{"pins":[{"identity":"shared","state":{"version":"1.0","revision":"a"}}]}\n' > "$kit"
	printf '{"pins":[{"identity":"swift-snapshot-testing","state":{"version":"1.19.6","revision":"b"}}]}\n' > "$snapshots"
	jq -s '{pins:[.[].pins[]]}' "$kit" "$snapshots" > "$project"
}
check_pins() { snapshot_make check-resolved PACKAGE_RESOLVED="$kit" SNAPSHOT_KIT_RESOLVED="$snapshots" PROJECT_RESOLVED="$project"; }
reset_pins
check_pins
expect_status 0
jq '.pins += [{"identity":"shared","state":{"version":"2.0","revision":"c"}}]' "$snapshots" > "$work/changed.json"
mv "$work/changed.json" "$snapshots"
check_pins
expect_status 2
expect_in "$work/out" 'pin shared differently'
expect_in "$work/out" 'commit all three'
reset_pins
printf '{"pins":[]}\n' > "$project"
check_pins
expect_status 2
expect_in "$work/out" "lockfiles together differ from the project's"
expect_in "$work/out" 'commit all three'
for invalid in missing wrong-version in-kit; do
	reset_pins
	case "$invalid" in
		missing) printf '{"pins":[]}\n' > "$snapshots" ;;
		wrong-version) sed 's/1.19.6/1.19.5/' "$snapshots" > "$work/changed.json"; mv "$work/changed.json" "$snapshots" ;;
		in-kit) jq -s '{pins:[.[].pins[]]}' "$kit" "$snapshots" > "$work/changed.json"; mv "$work/changed.json" "$kit" ;;
	esac
	jq -s '{pins:[.[].pins[]] | unique}' "$kit" "$snapshots" > "$project"
	check_pins
	expect_status 2
	expect_in "$work/out" 'SnapshotTesting 1.19.6 belongs to CircuitTimerSnapshotKit and the project only'
	expect_in "$work/out" 'commit all three'
done

describe 'Single snapshot: one selected case, language and actual process size'
for variant in en-large ru-ax5; do
	reset_trace
	language=${variant%-*}; size=${variant#*-}
	snapshot_make test-snapshot TEST=test_probe_matchesReference SNAPSHOT_LANGUAGE="$language" SNAPSHOT_TEXT_SIZE="$size"
	expect_status 0
	expect_equal "$(grep -c '^bundle:' "$TRACE/calls" || true)" 1
	expect_in "$TRACE/calls" "environment:never $size"
	expect_in "$TRACE/calls" "check:never $language $size 0"
	expect_in "$TRACE/calls" 'test_probe_matchesReference'
	arguments=$(find "$TRACE" -name '*.args' -print | head -1)
	if [ -n "$arguments" ]; then
		expect_in "$arguments" '-only-testing:CircuitTimerSnapshotTests/SnapshotTests/ProbeSnapshotTests/test_probe_matchesReference(textSize:)'
		case "$size" in large) category=UICTContentSizeCategoryL ;; ax5) category=UICTContentSizeCategoryAccessibilityXXXL ;; esac
		expect_in "$arguments" "SNAPSHOT_CONTENT_SIZE_CATEGORY=$category"
	else fail 'xcodebuild did not receive the selected case'; fi
	expect_not_in "$TRACE/calls" 'check:--same-cases'
done
reset_trace
snapshot_make test-snapshot TEST=test_probe_matchesReference
expect_status 0
expect_in "$TRACE/calls" 'environment:never large'
expect_in "$TRACE/calls" 'check:never en large'

describe 'Single snapshot: record then compare exactly the same selection'
reset_trace
snapshot_make record-snapshot TEST=test_probe_matchesReference
expect_status 0
expect_equal "$(grep -c '^bundle:' "$TRACE/calls" || true)" 2
expect_equal "$(grep '^environment:' "$TRACE/calls" | sed 's/^environment:\([^ ]*\).*/\1/' | uniq)" 'failed
never'
expect_equal "$(tail -2 "$TRACE/calls")" 'final-status
final-new-references'
reset_trace
FAIL_PAIR=failed-en-large snapshot_make record-snapshot TEST=test_probe_matchesReference
expect_status 2
expect_not_in "$TRACE/calls" 'check:never'
expect_not_in "$TRACE/calls" final-status
reset_trace
FAIL_PAIR=never-en-large snapshot_make record-snapshot TEST=test_probe_matchesReference
expect_status 2
expect_equal "$(grep -c '^bundle:' "$TRACE/calls" || true)" 2
expect_not_in "$TRACE/calls" final-status

describe 'Single snapshot: reject invalid input and unknown selection before Xcode'
for target in test-snapshot record-snapshot; do
	for invalid in 'TEST=' 'TEST=not/a/function' 'SNAPSHOT_LANGUAGE=de' 'SNAPSHOT_LANGUAGE=en ru' 'SNAPSHOT_TEXT_SIZE=medium'; do
		reset_trace
		snapshot_make "$target" TEST=test_probe_matchesReference "$invalid"
		expect_status 2
		expect_equal "$(cat "$TRACE/calls")" ''
	done
	reset_trace
	FAIL_SELECTION=1 snapshot_make "$target" TEST=test_unknown
	expect_status 2
	expect_in "$work/out" 'unknown snapshot test'
	expect_equal "$(cat "$TRACE/calls")" ''
	reset_trace
	CI=true snapshot_make "$target" TEST=test_probe_matchesReference
	expect_status 2
	expect_in "$work/out" 'local only'
	expect_equal "$(cat "$TRACE/calls")" ''
	reset_trace
	snapshot_make "$target" TEST=test_probe_matchesReference TEST_FLAGS='-only-testing:Another'
	expect_status 2
	expect_in "$work/out" 'would select or repeat cases'
done
reset_trace
DIRTY_REFERENCES=1 snapshot_make record-snapshot TEST=test_probe_matchesReference
expect_status 2
expect_in "$work/out" 'review and commit reference changes'
expect_equal "$(cat "$TRACE/calls")" ''
reset_trace
snapshot_make record-snapshot TEST=test_probe_matchesReference DESTINATION="$second"
expect_status 2
expect_in "$work/out" 'references require'
expect_equal "$(cat "$TRACE/calls")" ''

finish
