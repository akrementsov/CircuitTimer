#!/usr/bin/env bash
# Exercise the real checker with source/reference inventories, journals and xcresulttool-shaped reports.
. "$(dirname "$0")/lib.sh"

fixture="$root/scripts/tests/fixtures/snapshots/passed.json"
repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/CircuitTimerSnapshotTests/__Snapshots__/Probe" "$work/bin"
cp "$root/scripts/check-snapshot-run.sh" "$repo/scripts/"
git -C "$repo" init -q
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3 $4 $5" = 'xcresulttool get test-results tests --path' ] || exit 64
cat "$6/tests.json"
EOF
chmod +x "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
checker="$repo/scripts/check-snapshot-run.sh"
bundle="$work/Probe.xcresult"
artifacts="$work/artifacts"
source_file="$repo/CircuitTimerSnapshotTests/ProbeSnapshotTests.swift"
reference_dir="$repo/CircuitTimerSnapshotTests/__Snapshots__/Probe"

reset_case() {
	rm -rf "$artifacts" "$repo/CircuitTimerSnapshotTests"
	mkdir -p "$bundle" "$artifacts" "$reference_dir"
	cp "$fixture" "$bundle/tests.json"
	cat > "$source_file" <<'EOF'
@Suite
struct ProbeSnapshotTests {
@Test(arguments: SnapshotTextSize.currentCases())
func test_list_loaded_matchesReference(textSize: SnapshotTextSize) {}
@Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
func test_list_empty_matchesReference(textSize: SnapshotTextSize) {}
}
EOF
	printf '# runtime iOS 27.0 (24A335)\n# text-size large UICTContentSizeCategoryL\n' > "$artifacts/snapshots.tsv"
	for name in loaded empty; do
		key="test_list_${name}_matchesReference.en-large"
		printf '%s\tProbe/%s.png\tfirst\tpassed\n' "$key" "$key" >> "$artifacts/snapshots.tsv"
		: > "$reference_dir/$key.png"
	done
	git -C "$repo" add -A
}

edit_report() {
	jq "$1" "$bundle/tests.json" > "$work/edited.json"
	mv "$work/edited.json" "$bundle/tests.json"
}

edit_journal() {
	sed "$1" "$artifacts/snapshots.tsv" > "$work/edited.tsv"
	mv "$work/edited.tsv" "$artifacts/snapshots.tsv"
}

check() { run "$checker" "${1:-never}" en large "${2:-0}" "$bundle" "$artifacts"; }
reject() { check; expect_status 1; expect_in "$work/out" "$1"; }

describe 'S037: successful comparison, runtime, second mount and CI notices'
reset_case
edit_journal 's/first/second/'
run env GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$work/summary" "$checker" never en large 0 "$bundle" "$artifacts"
expect_status 0
expect_in "$work/out" 'en-large: iOS 27.0 (24A335); 2 of 2 snapshots matched only on the second mount'
expect_in "$work/out" '::notice::Second mount: test_list_loaded_matchesReference.en-large'
expect_in "$work/summary" 'Second mount: test_list_empty_matchesReference.en-large'

describe 'S038: only a confirmed recording permits a failed case and xcodebuild status'
reset_case
edit_report '(.. | objects | select(.nodeType == "Arguments" and .name == "large") | .result) = "Failed"'
edit_journal 's/first.passed$/second\trecorded/'
check failed 65
expect_status 0

describe 'S079: malformed invocations'
for arguments in 'other en large 0' 'never de large 0' 'never en medium 0' 'never en large abc' 'never en large -1'; do
	# The deliberate splitting represents separate invalid command-line arguments.
	run "$checker" $arguments "$bundle" "$artifacts"
	expect_status 2
	expect_in "$work/out" 'usage:'
done
run "$checker"
expect_status 2

describe 'S080: jq absent'
mkdir -p "$work/no-jq"
ln -s "$(command -v bash)" "$work/no-jq/bash"
run env PATH="$work/no-jq" "$checker" never en large 0 "$bundle" "$artifacts"
expect_status 1
expect_in "$work/out" 'jq is required'

describe 'S081: missing and unreadable bundle'
reset_case
run "$checker" never en large 0 "$work/missing" "$artifacts"
expect_status 1
expect_in "$work/out" 'no snapshot cases ran'
rm "$bundle/tests.json"
reject 'could not read'

describe 'M1: malformed JSON and JSON expression failure'
for input in 'not JSON' '{"testNodes":[{"nodeType":"Test Case","name":42}]}'; do
	reset_case
	printf '%s\n' "$input" > "$bundle/tests.json"
	reject 'unexpected result bundle or journal format'
done

describe 'S082/S083: valid JSON with no cases or no device'
reset_case
edit_report '.testNodes = []'
reject 'no snapshot cases ran'
reset_case
edit_report '.devices = []'
reject 'no test device in result bundle'
expect_not_in "$work/out" 'unexpected snapshot device'
reset_case
printf '{}\n' > "$bundle/tests.json"
reject 'no snapshot cases ran'
expect_in "$work/out" 'no test device in result bundle'

describe 'G06: each device constraint is enforced independently'
for change in '.devices[0].platform = "iOS"' '.devices[0].modelName = "iPhone 15"' '.devices[0].osVersion = "27.1"'; do
	reset_case
	edit_report "$change"
	reject 'unexpected snapshot device:'
done

describe 'S084: repetitions cannot hide a failed first execution'
reset_case
edit_report '.testNodes[0].children[0].children[0].children = [{"nodeType":"Repetition","name":"Retry 1"}]'
reject 'Xcode repetitions are not allowed'

describe 'S085/S086: applicable skips and missing size arguments'
reset_case
edit_report '.testNodes[0].children[0].children[0].result = "Skipped"'
reject 'skipped snapshot node'
reset_case
edit_report '.testNodes[0].children[0].children = []'
reject 'snapshot tests take text sizes as arguments'

describe 'S087: duplicate source functions and duplicate Test Cases'
reset_case
cp "$source_file" "$repo/CircuitTimerSnapshotTests/DuplicateSnapshotTests.swift"
reject 'duplicate snapshot function in sources'
reset_case
edit_report '.testNodes[0].children += [.testNodes[0].children[0]]'
reject 'duplicate Test Case name'

describe 'S088: missing and unknown functions'
reset_case
edit_report '.testNodes[0].children |= .[1:]'
reject 'snapshot function did not run'
reset_case
edit_report '.testNodes[0].children[0].name = "test_unknown(textSize:)"'
reject 'Test Case has no snapshot function in sources'

describe 'S089: large-only cases are empty, rather than skipped, in ax5'
reset_case
edit_report '(.testNodes[0].children[0].children[0].name) = "ax5" | .testNodes[0].children[1].children = []'
printf '# runtime iOS 27.0\n# text-size ax5 UICTContentSizeCategoryAccessibilityXXXL\ntest_list_loaded_matchesReference.en-ax5\tProbe/test_list_loaded_matchesReference.en-ax5.png\tfirst\tpassed\n' > "$artifacts/snapshots.tsv"
run "$checker" never en ax5 0 "$bundle" "$artifacts"
expect_status 0
edit_report '.testNodes[0].children[1].children = [{"nodeType":"Arguments","name":"ax5","result":"Passed"}]'
run "$checker" never en ax5 0 "$bundle" "$artifacts"
expect_status 1
expect_in "$work/out" 'arguments ran outside its declared text sizes'

describe 'S090: wrong size and duplicate argument key'
reset_case
edit_report '.testNodes[0].children[0].children[0].name = "ax5"'
reject 'argument differs from process text size'
reset_case
edit_report '.testNodes[0].children[0].children += [.testNodes[0].children[0].children[0]]'
reject 'duplicate snapshot case'

describe 'S091: both process headers are required'
for change in '1d' '2d' '2s/large/ax5/' '2s/UICTContentSizeCategoryL/wrong/'; do
	reset_case
	edit_journal "$change"
	check
	expect_status 1
	expect_in "$work/out" 'capture journal'
done

describe 'S092: malformed rows, attempts, outcomes, keys and paths'
for change in '3s/first.passed$/first/' '3s/first/third/' '3s/passed/unknown/' '3s@Probe/@wrong/@' '3s/loaded/unknown/g'; do
	reset_case
	edit_journal "$change"
	check
	expect_status 1
	case "$change" in
		'3s/first.passed$/first/') expect_in "$work/out" 'four tab-separated fields' ;;
		'3s/first/third/') expect_in "$work/out" 'invalid capture attempt' ;;
		'3s/passed/unknown/') expect_in "$work/out" 'invalid capture outcome' ;;
		'3s@Probe/@wrong/@') expect_in "$work/out" 'journal path differs from reference' ;;
		*) expect_in "$work/out" 'journal key has no snapshot case' ;;
	esac
done
reset_case
sed -n '3p' "$artifacts/snapshots.tsv" >> "$artifacts/snapshots.tsv"
reject 'duplicate capture journal key'
reset_case
edit_journal '3s/\.png/.jpg/'
reject 'journal PNG path does not match its key'

describe 'S093/S094: missing rows and capture errors keep the owning failure message'
for outcome in missing-row missing-journal error; do
	reset_case
	edit_report '.testNodes[0].children[0].children[0] |= (.result="Failed" | .children=[{"nodeType":"Failure Message","name":"Probe capture failed at source"}])'
	case "$outcome" in
		missing-row) edit_journal '3d' ;;
		missing-journal) rm "$artifacts/snapshots.tsv" ;;
		error) edit_journal '3s/passed/error/' ;;
	esac
	check
	expect_status 1
	expect_in "$work/out" 'Probe capture failed at source'
	if [ "$outcome" = error ]; then expect_in "$work/out" 'capture error';
	else expect_in "$work/out" 'expected one capture journal row, found 0'; fi
done

describe 'S095: orphan, duplicate and unsupported reference inventories'
for path in 'Other/test_orphan.en-large.png' 'Other/test_list_loaded_matchesReference.en-large.png' 'Other/test_unknown.en-medium.png'; do
	reset_case
	mkdir -p "$repo/CircuitTimerSnapshotTests/__Snapshots__/Other"
	: > "$repo/CircuitTimerSnapshotTests/__Snapshots__/$path"
	git -C "$repo" add -A
	check
	expect_status 1
	case "$path" in
		*test_orphan*) expect_in "$work/out" 'orphan reference PNG' ;;
		*test_list_loaded*) expect_in "$work/out" 'duplicate reference PNG key' ;;
		*test_unknown*) expect_in "$work/out" 'unsupported reference text size' ;;
	esac
done
reset_case
edit_journal '3s@Probe/@Other/@'
reject 'journal path differs from reference'

describe 'S096: never requires Passed, passed and a successful command'
for change in result outcome status; do
	reset_case
	case "$change" in
		result) edit_report '.testNodes[0].children[0].children[0].result = "Failed"' ;;
		outcome) edit_journal '3s/passed/recorded/' ;;
	esac
	if [ "$change" = status ]; then check never 65; else check; fi
	expect_status 1
done

describe 'S097: record accepts only corresponding Passed/passed or Failed/recorded'
for change in unrecorded passed-recorded skipped status; do
	reset_case
	case "$change" in
		unrecorded) edit_report '.testNodes[0].children[0].children[0].result = "Failed"' ;;
		passed-recorded) edit_journal '3s/passed/recorded/' ;;
		skipped) edit_report '.testNodes[0].children[0].children[0].result = "Unknown"' ;;
	esac
	if [ "$change" = status ]; then check failed 65; else check failed; fi
	expect_status 1
done

describe 'S098: inventory syntax fails closed even in a non-final source file'
for declaration in '@Test(arguments: [.large])' '@Test(arguments:'; do
	reset_case
	printf '%s\nfunc test_bad(textSize: SnapshotTextSize) {}\n' "$declaration" > "$repo/CircuitTimerSnapshotTests/ASnapshotTests.swift"
	reject 'test_bad: use currentCases() or currentCases(in: [.large]) on one @Test line'
done

describe 'S005/S100/G07: compare unions across all four bundles'
reset_case
for variant in en-large en-ax5 ru-large ru-ax5; do
	mkdir -p "$work/$variant"
	case "$variant" in
		*-large) cp "$fixture" "$work/$variant/tests.json" ;;
		*-ax5) jq '.testNodes[0].children |= .[0:1] | .testNodes[0].children[0].children[0].name="ax5"' "$fixture" > "$work/$variant/tests.json" ;;
	esac
done
same_cases() { run "$checker" --same-cases "$work/en-large" "$work/en-ax5" "$work/ru-large" "$work/ru-ax5"; }
same_cases
expect_status 0
cp "$work/ru-ax5/tests.json" "$work/saved.json"
printf '{"testNodes":[]}\n' > "$work/ru-ax5/tests.json"
same_cases
expect_status 1
expect_in "$work/out" 'en and ru ran different snapshot cases'
printf '{"testNodes":[]}\n' > "$work/ru-large/tests.json"
same_cases
expect_status 1
expect_in "$work/out" 'no snapshot cases ran in one of the languages'
for variant in en-large en-ax5 ru-large ru-ax5; do
	cp "$fixture" "$work/ru-large/tests.json"
	cp "$work/saved.json" "$work/ru-ax5/tests.json"
	cp "$work/$variant/tests.json" "$work/before.json"
	printf 'invalid JSON\n' > "$work/$variant/tests.json"
	same_cases
	checks=$((checks + 1))
	if [ "$status" -eq 0 ]; then fail 'malformed JSON passed the matrix check'; fi
	expect_not_in "$work/out" 'en and ru ran different snapshot cases'
	expect_not_in "$work/out" 'no snapshot cases ran in one of the languages'
	expect_not_in "$work/out" 'unexpected result bundle or journal format'
	cp "$work/before.json" "$work/$variant/tests.json"
done

describe 'Single snapshot: resolve a source test before its first reference exists'
reset_case
rm "$reference_dir/test_list_loaded_matchesReference.en-large.png"
run "$checker" --select test_list_loaded_matchesReference ax5
expect_status 0
expect_in "$work/out" 'CircuitTimerSnapshotTests/SnapshotTests/ProbeSnapshotTests/test_list_loaded_matchesReference(textSize:)'
for selected in test_unknown 'bad/selection'; do
	run "$checker" --select "$selected" large
	expect_status 1
done
run "$checker" --select test_list_empty_matchesReference ax5
expect_status 1
expect_in "$work/out" 'does not support ax5'
cp "$source_file" "$repo/CircuitTimerSnapshotTests/DuplicateSnapshotTests.swift"
run "$checker" --select test_list_loaded_matchesReference large
expect_status 1
expect_in "$work/out" 'not unique'

describe 'Single snapshot: comments and helper types cannot replace the annotated suite'
reset_case
cat > "$source_file" <<'EOF'
struct BeforeSuite {}
extension SnapshotTests {
    @Suite
    @MainActor
    private struct ProbeSnapshotTests {
        struct Helper {
            let value: String
        }
        // construct a state; struct PretendSuite is only a comment.
        @Test(arguments: SnapshotTextSize.currentCases())
        func test_list_loaded_matchesReference(textSize: SnapshotTextSize) {}
        struct OtherHelper {}
        @Test(arguments: SnapshotTextSize.currentCases(in: [.large]))
        func test_list_empty_matchesReference(textSize: SnapshotTextSize) {}
    }
}
struct AfterSuite {}
EOF
for selected in test_list_loaded_matchesReference test_list_empty_matchesReference; do
    run "$checker" --select "$selected" large
    expect_status 0
    expect_equal "$(cat "$work/out")" "CircuitTimerSnapshotTests/SnapshotTests/ProbeSnapshotTests/$selected(textSize:)"
done

describe 'Single snapshot: scope references but require exactly the selected execution'
reset_case
edit_report '.testNodes[0].children |= .[0:1]'
sed -n '1,3p' "$artifacts/snapshots.tsv" > "$work/one.tsv"
mv "$work/one.tsv" "$artifacts/snapshots.tsv"
selected_check() { run "$checker" "${1:-never}" en large "${2:-0}" "$bundle" "$artifacts" test_list_loaded_matchesReference; }
selected_check
expect_status 0
# The identical partial result must still fail the full-matrix check.
check
expect_status 1
expect_in "$work/out" 'snapshot function did not run'
selected_check
expect_status 0
edit_report '.testNodes=[]'
selected_check
expect_status 1
expect_in "$work/out" 'no snapshot cases ran'
reset_case
selected_check
expect_status 1
expect_in "$work/out" 'unselected snapshot function ran'
reset_case
edit_report '.testNodes[0].children |= .[0:1] | .testNodes[0].children[0].children[0].result="Skipped"'
sed -n '1,3p' "$artifacts/snapshots.tsv" > "$work/one.tsv"; mv "$work/one.tsv" "$artifacts/snapshots.tsv"
selected_check
expect_status 1
expect_in "$work/out" 'skipped snapshot node'
CI=true selected_check
expect_status 1
expect_in "$work/out" 'local only'

finish
