#!/usr/bin/env bash
# Usage: check-snapshot-run.sh never|failed en|ru XCODEBUILD_STATUS BUNDLE ARTIFACTS
# Or: check-snapshot-run.sh --same-cases EN_BUNDLE RU_BUNDLE
# A successful xcodebuild is not enough: every snapshot function, argument and committed reference must run once,
# and every case must have exactly one capture journal row. Recording accepts only confirmed reference writes.
set -euo pipefail

fail() {
	echo "check-snapshot-run: $*" >&2
	exit 1
}

usage() {
	echo "usage: check-snapshot-run.sh never|failed en|ru STATUS BUNDLE ARTIFACTS | --same-cases EN_BUNDLE RU_BUNDLE" >&2
	exit 2
}

if [ "$#" -eq 3 ] && [ "$1" = --same-cases ]; then
	compare=true
elif [ "$#" -eq 5 ]; then
	compare=false
	mode=$1; language=$2; status=$3; bundle=$4; artifacts=$5
	case "$mode" in never|failed) ;; *) usage ;; esac
	case "$language" in en|ru) ;; *) usage ;; esac
	case "$status" in ''|*[!0-9]*) usage ;; esac
else
	usage
fi

command -v jq >/dev/null || fail "jq is required"
work=$(mktemp -d "${TMPDIR:-/tmp}/circuittimer-snapshots.XXXXXX")
trap 'rm -rf "$work"' EXIT

read_bundle() {
	[ -d "$1" ] || fail "no result bundle at $1; no snapshot cases ran"
	xcrun xcresulttool get test-results tests --path "$1" > "$2" || fail "could not read $1"
}

# Both operations use the same argument keys; each result bundle is read only once per invocation.
JQ_CASES='
	def cases:
		[.. | objects | select(.nodeType == "Test Case")
			| . as $test
			| (.name | sub("\\(.*$"; "")) as $function
			| [(.children // [])[] | select(.nodeType == "Arguments")] as $arguments
			| {function: $function, arguments: $arguments}];
	def keys_without_language:
		[cases[] | .function as $function | .arguments[] | "\($function).\(.name)"] | sort;
'

if [ "$compare" = true ]; then
	read_bundle "$2" "$work/en.json"
	read_bundle "$3" "$work/ru.json"
	jq -r "$JQ_CASES keys_without_language[]" "$work/en.json" > "$work/en-keys"
	jq -r "$JQ_CASES keys_without_language[]" "$work/ru.json" > "$work/ru-keys"
	[ -s "$work/en-keys" ] && [ -s "$work/ru-keys" ] || fail "no snapshot cases ran in one of the languages"
	if ! diff -u "$work/en-keys" "$work/ru-keys"; then
		fail "en and ru ran different snapshot cases"
	fi
	exit 0
fi

read_bundle "$bundle" "$work/tests.json"
root=$(cd "$(dirname "$0")/.." && pwd)
snapshots=${SNAPSHOTS_DIR:-CircuitTimerSnapshotTests/__Snapshots__}
case "$snapshots" in /*) ;; *) snapshots="$root/$snapshots" ;; esac

# The references are the manifest; new test functions still have to run before their first reference exists.
git -C "$root" ls-files -- "$snapshots" | awk '/\.png$/' > "$work/references"
for file in "$root"/CircuitTimerSnapshotTests/*SnapshotTests.swift; do
	[ -f "$file" ] || continue
	awk '
		/func[[:space:]]+test_[A-Za-z0-9_]+\(/ {
			name = $0
			sub(/^.*func[[:space:]]+/, "", name)
			sub(/\(.*/, "", name)
			print name
		}
	' "$file"
done > "$work/functions"
if [ -f "$artifacts/snapshots.tsv" ]; then
	cp "$artifacts/snapshots.tsv" "$work/journal"
else
	: > "$work/journal"
fi

# Keep failure messages on the argument that owns them, including errors before a journal row could be written.
JQ_VALIDATE='
	def messages: [.. | objects | select(.nodeType == "Failure Message") | .name] | join("\n");
	def lines: split("\n") | map(select(length > 0));
	. as $report
	| cases as $tests
	| [$tests[] | .function as $function | .arguments[]
		| {key: "\($function).\($lang)-\(.name)", function: $function, argument: .name,
			result: .result, messages: messages}] as $cases
	| ($functions | lines) as $functions
	| ($references | lines | map(select(endswith(".png"))
		| {path: ltrimstr($prefix), key: (split("/")[-1] | sub("\\.png$"; ""))}
		| select(.key | test("\\.\($lang)-[^/]+$")))) as $references
	| ($journal | lines) as $journalLines
	| [$journalLines[] | select(startswith("#") | not) | split("\t")] as $fields
	| [$fields[] | {key: .[0], path: .[1], attempt: .[2], outcome: .[3]}] as $rows
	| [
		(if ($cases | length) == 0 then "no snapshot cases ran" else empty end),
		(if ($report.devices // [] | length) == 0 then "no test device in result bundle" else empty end),
		($report.devices[]? | select(.platform != "iOS Simulator" or .modelName != "iPhone 17" or .osVersion != "27.0")
			| "unexpected snapshot device: \(.platform) / \(.modelName) / \(.osVersion)"),
		($report | .. | objects | select(.nodeType == "Repetition") | "Xcode repetitions are not allowed"),
		($report | .. | objects | select(.result == "Skipped") | "skipped snapshot node: \(.name)"),
		($tests[] | select((.arguments | length) == 0) | "\(.function): snapshot tests take text sizes as arguments"),
		($tests | group_by(.function)[] | select(length > 1) | "duplicate Test Case name: \(.[0].function)"),
		($functions | group_by(.)[] | select(length > 1) | "duplicate snapshot function in sources: \(.[0])"),
		($functions[] as $function | select(any($tests[]; .function == $function) | not)
			| "snapshot function did not run: \($function)"),
		($tests[] | .function as $function | select($functions | index($function) | not)
			| "Test Case has no snapshot function in sources: \($function)"),
		($cases[] | select(.argument != "large" and .argument != "ax5") | "\(.key): unsupported text-size argument"),
		($cases | group_by(.key)[] | select(length > 1) | "duplicate snapshot case: \(.[0].key)"),
		(if ($journalLines[0] // "" | startswith("# runtime ") | not) then "missing capture journal runtime header" else empty end),
		($fields[] | select(length != 4) | "capture journal rows must have four tab-separated fields"),
		($rows | group_by(.key)[] | select(length > 1) | "duplicate capture journal key: \(.[0].key)"),
		($rows[] | select(.attempt != "first" and .attempt != "second") | "\(.key): invalid capture attempt"),
		($rows[] | select(.outcome != "passed" and .outcome != "recorded" and .outcome != "failed" and .outcome != "error")
			| "\(.key): invalid capture outcome"),
		($rows[] | .key as $key | select(.path == null or (.path | endswith("/\($key).png") | not))
			| "\(.key): journal PNG path does not match its key"),
		($rows[] | .key as $key | select(any($cases[]; .key == $key) | not) | "journal key has no snapshot case: \($key)"),
		($references | group_by(.key)[] | select(length > 1) | "duplicate reference PNG key: \(.[0].key)"),
		($references[] as $reference | select(any($cases[]; .key == $reference.key) | not)
			| "orphan reference PNG: \($reference.path)"),
		($references[] as $reference | $rows[] | select(.key == $reference.key and .path != $reference.path)
			| "\(.key): journal path differs from reference \($reference.path)"),
		($cases[] as $case | [$rows[] | select(.key == $case.key)] as $matches
			| if ($matches | length) != 1 then
				"\($case.key): expected one capture journal row, found \($matches | length)\n\($case.messages)"
			elif $matches[0].outcome == "error" then
				"\($case.key): capture error\n\($case.messages)"
			elif $mode == "never" and ($case.result != "Passed" or $matches[0].outcome != "passed") then
				"\($case.key): comparison did not pass (\($case.result), \($matches[0].outcome))\n\($case.messages)"
			elif $mode == "failed" and (
				($case.result != "Passed" and $case.result != "Failed") or
				($case.result == "Failed" and $matches[0].outcome != "recorded") or
				($case.result == "Passed" and $matches[0].outcome != "passed")
			) then
				"\($case.key): result and confirmed recording disagree (\($case.result), \($matches[0].outcome))\n\($case.messages)"
			else empty end),
		(if $mode == "never" and $status != 0 then "comparison xcodebuild exited \($status)" else empty end),
		(if $mode == "failed" and $status != 0 and (any($rows[]; .outcome == "recorded") | not)
			then "xcodebuild exited \($status) without a confirmed recording" else empty end)
	] as $errors
	| {errors: $errors,
		runtime: [$report.devices[]? | "\(.osVersion) (\(.osBuildNumber))"] | unique | join(", "),
		count: ($cases | length), second: [$rows[] | select(.attempt == "second" and .outcome == "passed") | .key]}
'

jq --arg lang "$language" --arg mode "$mode" --argjson status "$status" --arg prefix "${snapshots#"$root"/}/" \
	--rawfile functions "$work/functions" --rawfile references "$work/references" --rawfile journal "$work/journal" \
	"$JQ_CASES $JQ_VALIDATE" "$work/tests.json" > "$work/validation.json" || fail "unexpected result bundle or journal format"

notice() {
	printf '%s\n' "check-snapshot-run: $1"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "- $1" >> "$GITHUB_STEP_SUMMARY"; fi
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		message=${1//%/%25}; message=${message//$'\r'/%0D}; message=${message//$'\n'/%0A}
		printf '::notice::%s\n' "$message"
	fi
}

notice "$(jq -r --arg lang "$language" '"\($lang): iOS \(.runtime); \(.second | length) of \(.count) snapshots matched only on the second mount"' "$work/validation.json")"
while IFS= read -r key; do notice "Second mount: $key"; done < <(jq -r '.second[]' "$work/validation.json")
if [ "$(jq '.errors | length' "$work/validation.json")" -gt 0 ]; then
	jq -r '.errors[] | "check-snapshot-run: " + .' "$work/validation.json" >&2
	exit 1
fi
