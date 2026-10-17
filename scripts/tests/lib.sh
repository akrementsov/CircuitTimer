# Sourced by every scripts/tests/test-*.sh: a scratch folder removed on exit, checks that count failures, and the
# verdict. Runs with bash 3.2 and with BSD or GNU tools, so on a Mac and on CI's Linux lint job alike.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
test_name=$(basename "$0" .sh)
# Inside the repository when SwiftLint must see the files: CI runs it in Docker, which mounts only the repository.
if [ "${SCRATCH_IN_REPO:-}" = 1 ]; then
	scratch_parent="$root/.test-scripts"
	mkdir -p "$scratch_parent"
	trap 'rm -rf "$work"; rmdir "$scratch_parent" 2>/dev/null || true' EXIT
else
	scratch_parent=${TMPDIR:-/tmp}
	trap 'rm -rf "$work"' EXIT
fi
work=$(mktemp -d "$scratch_parent/$test_name.XXXXXX")
# The scripts under test would write into the real CI step's annotations, outputs and summary, and a nested make
# would take the calling make's variables.
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY CI MAKEFLAGS MFLAGS MAKELEVEL

checks=0
failures=0
case_name=""

# Names the case that the following checks belong to.
describe() {
	case_name=$1
}

fail() {
	failures=$((failures + 1))
	echo "FAIL $test_name › $case_name: $*" >&2
}

# Runs a command, keeping its exit status in `status` and its output, stdout and stderr together, in $work/out.
run() {
	set +e
	"$@" > "$work/out" 2>&1
	status=$?
	set -e
}

expect_status() {
	checks=$((checks + 1))
	if [ "$status" -ne "$1" ]; then
		fail "exit status $status, expected $1; output:"
		sed 's/^/    /' "$work/out" >&2
	fi
}

# expect_in FILE TEXT: the file has a line containing TEXT.
expect_in() {
	checks=$((checks + 1))
	if ! grep -qF -- "$2" "$1"; then
		fail "$(basename "$1") has no line with: $2"
		sed 's/^/    /' "$1" >&2
	fi
}

expect_not_in() {
	checks=$((checks + 1))
	if grep -qF -- "$2" "$1"; then
		fail "$(basename "$1") has a line with: $2"
	fi
}

expect_equal() {
	checks=$((checks + 1))
	if [ "$1" != "$2" ]; then
		fail "got:"
		printf '%s\n' "$1" | sed 's/^/    /' >&2
		echo "  expected:" >&2
		printf '%s\n' "$2" | sed 's/^/    /' >&2
	fi
}

expect_exists() {
	checks=$((checks + 1))
	if [ ! -e "$1" ]; then
		fail "$1 is missing"
	fi
}

expect_missing() {
	checks=$((checks + 1))
	if [ -e "$1" ]; then
		fail "$1 exists"
	fi
}

finish() {
	if [ "$failures" -gt 0 ]; then
		echo "$test_name: $failures of $checks checks failed" >&2
		exit 1
	fi
	echo "$test_name: $checks checks passed"
}
