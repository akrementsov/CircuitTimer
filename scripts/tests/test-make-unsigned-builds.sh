#!/usr/bin/env bash
# Tests that every simulator build without a signature names no CloudKit container: CloudKit traps a process that uses
# one without the iCloud entitlement. Stand-ins replace xcodebuild, xcrun, scripts/run-tests.sh and the intent check.
. "$(dirname "$0")/lib.sh"

repo="$work/repo"
mkdir -p "$repo/scripts" "$work/bin" "$work/trace"
cp "$root/Makefile" "$repo/"
cat > "$repo/scripts/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
mkdir -p "$1"
shift
"$@"
EOF
printf '%s\n' 'import sys' > "$repo/scripts/check-activity-intents.py"
# Keeps each call's arguments, one per line, in its own numbered file.
cat > "$work/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -eu
calls=$(find "$TRACE" -name 'call-*.args' | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$TRACE/call-$((calls + 1)).args"
EOF
cat > "$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf '{"passedTests":1,"skippedTests":0,"failedTests":0}\n'
EOF
chmod +x "$repo/scripts/"* "$work/bin/"*
export PATH="$work/bin:$PATH" TRACE="$work/trace"

# The Makefile's own targets that build or test on the simulator, with the number of xcodebuild runs each makes.
while read -r target runs; do
	describe "$target builds without a container"
	rm -rf "$TRACE"
	mkdir -p "$TRACE"
	run make -s -C "$repo" "$target" TEST_RESULTS="$work/results" DERIVED_DATA="$work/dd" SOURCE_PACKAGES="$work/sp" \
		TEST_FLAGS= < /dev/null
	expect_status 0
	expect_equal "$(find "$TRACE" -name 'call-*.args' | wc -l | tr -d ' ')" "$runs"
	for arguments in "$TRACE"/call-*.args; do
		expect_line "$arguments" CODE_SIGNING_ALLOWED=NO
		expect_line "$arguments" CT_CLOUDKIT_CONTAINER=
		expect_equal "$(grep -c '^CT_CLOUDKIT_CONTAINER=' "$arguments")" 1
	done
done <<'EOF'
build-app 1
build-ui-tests 1
test-ui 1
build-snapshots 1
test-snapshot-contracts 2
EOF

finish
