#!/usr/bin/env bash
# Usage: report-test-results.sh BUNDLE...
# Reports each result bundle: an error annotation per failed test with its messages, a warning per test that
# passed only on a retry, and the 20 slowest tests, also into the step summary on CI. Outside GitHub Actions the
# failures and flaky tests print as plain text. Writes `flaky=` and `upload=` to $GITHUB_OUTPUT when it is set;
# `upload=true` asks CI to keep the bundles. Diagnostics only: it fails no run by itself.
set -euo pipefail

if [ $# -eq 0 ]; then
	echo "usage: report-test-results.sh BUNDLE..." >&2
	exit 2
fi

# A test case with every test bundle it belongs to; messages carry the arguments and repetition they failed in.
JQ_TESTS='
	def escape: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
	def property: escape | gsub(":"; "%3A") | gsub(","; "%2C");
	def msgs($run):
		(.children // [])[]
		| if .nodeType == "Failure Message" then
			(if $run == "" then .name else "[\($run)] \(.name)" end)
		elif .nodeType == "Arguments" or .nodeType == "Repetition" or .nodeType == "Test Case Run" then
			msgs(if $run == "" then .name else "\($run), \(.name)" end)
		else
			empty
		end;
	def cases(target):
		(if .nodeType == "Unit test bundle" or .nodeType == "UI test bundle" then .name else target end) as $target
		| if .nodeType == "Test Case" then
			{target: $target, test: .}
		else
			(.children // [])[] | cases($target)
		end;
	def annotation(kind; prefix):
		"\(.target)/\(.test.nodeIdentifier)" as $title
		| [.test | msgs("")] as $messages
		| (prefix + (if $messages == [] then "no failure message" else $messages | join("\n") end)) as $text
		| if $ci then
			"::\(kind) title=" + ($title | property) + "::" + ($text | escape)
		else
			"\(kind | ascii_upcase): \($title)\n" + ($text | split("\n") | map("    " + .) | join("\n"))
		end;
	[.testNodes[] | cases("")] as $cases
	| ($cases[] | select(.test.result == "Failed") | annotation("error"; "")),
	($cases[]
		| select(.test.result == "Passed" and any(.test | .. | objects; .nodeType == "Repetition" and .result == "Failed"))
		| annotation("warning"; "Passed only on a retry. "))
'

JQ_SLOWEST='
	[.. | objects | select(.nodeType == "Test Case" and .durationInSeconds != null)]
	| sort_by(-.durationInSeconds) | .[:20][]
	| "| \(.durationInSeconds * 10 | round / 10) | `\(.nodeIdentifier)` |"
'

summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		tee -a "$GITHUB_STEP_SUMMARY"
	else
		cat
	fi
}

# Annotations for GitHub Actions, plain text for a terminal.
ci=false
if [ -n "${GITHUB_ACTIONS:-}" ]; then
	ci=true
fi

warn() {
	if [ "$ci" = true ]; then
		echo "::warning::$1"
	else
		echo "WARNING: $1"
	fi
}

flaky=false
upload=false
for bundle in "$@"; do
	name=$(basename "$bundle")
	if [ ! -d "$bundle" ]; then
		echo "$name: no result bundle; the tests did not start"
		continue
	fi
	if ! tests=$(xcrun xcresulttool get test-results tests --path "$bundle"); then
		warn "$name: xcresulttool could not read the result bundle"
		upload=true
		continue
	fi
	if ! annotations=$(jq -r --argjson ci "$ci" "$JQ_TESTS" <<< "$tests"); then
		warn "$name: the result bundle has an unexpected format"
		upload=true
		continue
	fi
	if [ -n "$annotations" ]; then
		echo "$annotations"
		upload=true
		retried=$(grep -cE '^(::warning|WARNING:)' <<< "$annotations" || true)
		if [ "$retried" -gt 0 ]; then
			flaky=true
			echo "- $name: $retried test(s) passed only on a retry" | summary
		fi
	fi
	{
		echo "### Slowest tests in $name"
		echo
		echo '| Seconds | Test |'
		echo '|---:|---|'
		jq -r "$JQ_SLOWEST" <<< "$tests" || echo "| | the result bundle has an unexpected format |"
		echo
	} | summary
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "flaky=$flaky"
		echo "upload=$upload"
	} >> "$GITHUB_OUTPUT"
fi
