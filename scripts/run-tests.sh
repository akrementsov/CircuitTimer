#!/usr/bin/env bash
# Usage: run-tests.sh RESULT_BUNDLE COMMAND...
# Runs an xcodebuild test command with its own result bundle and a log next to it (`<bundle>.log` without
# `.xcresult`), so several runs keep apart. A runner that hangs before connecting to the simulator, which the CI
# image's simulator sometimes does, tests nothing and gets one retry; a failing test gets none here. Exits with the
# command's status. A failed local run prints its report; CI reports every bundle in a step of its own.
set -euo pipefail

if [ $# -lt 2 ]; then
	echo "usage: run-tests.sh RESULT_BUNDLE COMMAND..." >&2
	exit 2
fi
bundle=$1
shift
case "$bundle" in
	*.xcresult) ;;
	*)
		echo "run-tests: $bundle must end in .xcresult" >&2
		exit 2
		;;
esac
log="${bundle%.xcresult}.log"
here=$(cd "$(dirname "$0")" && pwd)
# What xcodebuild prints when the runner never reached the simulator.
HUNG_PATTERNS='The test runner hung before establishing connection|Test runner never began executing tests'

bundle_ran_tests() {
	[ -d "$bundle" ] \
		&& xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null \
			| jq -e '(.totalTestCount // 0) > 0' >/dev/null
}

# Runs the command once into the bundle, appending its output to the log; returns the command's status.
run_once() {
	"$@" -resultBundlePath "$bundle" 2>&1 | tee -a "$log"
}

mkdir -p "$(dirname "$bundle")"
# xcodebuild refuses an existing result bundle.
rm -rf "$bundle" "$log"

if run_once "$@"; then
	status=0
else
	status=$?
	if grep -qE "$HUNG_PATTERNS" "$log" && ! bundle_ran_tests; then
		message="The test runner hung before connecting; retrying $(basename "$bundle") once"
		echo "::warning::$message"
		if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
			echo "- $message" >> "$GITHUB_STEP_SUMMARY"
		fi
		echo "=== retry after hung runner ===" >> "$log"
		rm -rf "$bundle"
		if run_once "$@"; then
			status=0
		else
			status=$?
		fi
	fi
fi

if [ "$status" -ne 0 ]; then
	if [ -z "${GITHUB_ACTIONS:-}" ]; then
		"$here/report-test-results.sh" "$bundle" || echo "run-tests: could not report $bundle" >&2
	fi
	echo "Tests failed; result bundle $bundle, log $log" >&2
fi
exit "$status"
