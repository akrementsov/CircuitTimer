#!/usr/bin/env bash
# Usage: report-test-results.sh BUNDLE...
# Reports each result bundle: an error annotation per failed test with its messages, a warning per test that
# passed only on a retry, and the 20 tests with the most own time with how long each waited for the tests running in
# parallel, also into the step summary on CI. Outside GitHub Actions the failures and flaky tests print as plain text.
# Writes `flaky=` and `upload=` to $GITHUB_OUTPUT when it is set; `upload=true` asks CI to keep the bundles.
# Diagnostics only: it fails no run by itself.
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

# The 20 tests with the most own time, from the action log, which gives each run of a test (one per argument) its
# start and duration and puts it under the test process it ran in. Own time is an estimate: every moment of a run is
# split evenly among the runs going on in its process at that moment. Tests on the main actor take turns on its one
# thread, so most of their total time is waiting; tests off it share the CPU cores and get more than the estimate.
JQ_OWN='
	def runs($process):
		(if .domainType == "com.apple.dt.IDE.UnitTestLogSection.Worker" then .title else $process end) as $p
		| (if .testDetails.testName? != null and .startTime != null and .duration != null then
			{process: $p, test: "\(.testDetails.suiteName)/\(.testDetails.testName)", start: .startTime,
				end: (.startTime + .duration)}
		else
			empty
		end),
		((.subsections // [])[] | runs($p));
	def round2: . * 100 | round / 100;
	[runs("")] | group_by(.process) | map(
		# Spans between consecutive starts and ends, each with the number of runs going on; an end sorts before a
		# start at the same moment.
		([.[] | [.start, 1], [.end, -1]] | sort
			| reduce .[] as $event ({at: null, running: 0, spans: []};
				(if .at != null and $event[0] > .at and .running > 0 then
					.spans += [{from: .at, to: $event[0], running: .running}]
				else
					.
				end)
				| .at = $event[0] | .running += $event[1])
			| .spans) as $spans
		| map(. as $run
			| [$spans[] | select(.from >= $run.start and .to <= $run.end)] as $inside
			| . + {
				own: ([$inside[] | (.to - .from) / .running] | add // 0),
				crowd: ([$inside[] | (.to - .from) * .running] | add // 0)
			})
	) | add // []
	| group_by([.process, .test]) | map({
		test: .[0].test,
		own: (map(.own) | add),
		total: ((map(.end) | max) - (map(.start) | min)),
		atOnce: ((map(.end - .start) | add) as $length
			| if $length > 0 then (map(.crowd) | add) / $length else 1 end)
	})
	| sort_by(-.own) | .[:20][]
	| "| \(.own | round2) | \(.total - .own | round2) | \(.total | round2) | \(.atOnce | round) | `\(.test)` |"
'

# Without the log: the 20 longest tests by total time, waiting included.
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
	if log=$(xcrun xcresulttool get log --path "$bundle" --type action 2> /dev/null) \
		&& own=$(jq -r "$JQ_OWN" <<< "$log" 2> /dev/null) && [ -n "$own" ]; then
		{
			echo "### Slowest tests in $name"
			echo
			echo "Tests run in parallel, so a test's total time is mostly waiting for the others in its process." \
				"Own time is an estimate: each moment of a test is split evenly among the tests running then." \
				"At once is how many tests ran at a time on average, this one included."
			echo
			echo '| Own, s | Waited, s | Total, s | At once | Test |'
			echo '|---:|---:|---:|---:|---|'
			echo "$own"
			echo
		} | summary
	else
		{
			echo "### Slowest tests in $name"
			echo
			echo "The log has no test runs, so each time includes waiting for the tests that ran in parallel."
			echo
			echo '| Seconds | Test |'
			echo '|---:|---|'
			jq -r "$JQ_SLOWEST" <<< "$tests" || echo "| | the result bundle has an unexpected format |"
			echo
		} | summary
	fi
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "flaky=$flaky"
		echo "upload=$upload"
	} >> "$GITHUB_OUTPUT"
fi
