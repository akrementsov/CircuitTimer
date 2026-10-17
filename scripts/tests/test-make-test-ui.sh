#!/usr/bin/env bash
# Tests `make test-ui` up to xcodebuild, which a stand-in replaces: its paths per destination and its guard of
# UI_TEST_WORKERS. Make exits 2 when the recipe fails.
. "$(dirname "$0")/lib.sh"

# Records its arguments, one per line.
mkdir -p "$work/bin"
cat > "$work/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$XCODEBUILD_ARGUMENTS"
EOF
chmod +x "$work/bin/xcodebuild"
export PATH="$work/bin:$PATH" XCODEBUILD_ARGUMENTS="$work/arguments"

second='platform=iOS Simulator,name=iPhone 17 #2,OS=27.0'
oldest='platform=iOS Simulator,name=iPhone 15,OS=17.5'

# test_ui [VARIABLE=VALUE...]: `make test-ui` with its outputs in $work and its arguments recorded.
test_ui() {
	rm -f "$work/arguments"
	run make -s -C "$root" test-ui DESTINATION="$second" TEST_RESULTS="$work/results" DERIVED_DATA="$work/dd" \
		SOURCE_PACKAGES="$work/sp" TEST_FLAGS= "$@"
}

describe "paths per destination"
run make -n -C "$root" test-ui DESTINATION="$second" TEST_RESULTS="$work/results" DERIVED_DATA="$work/dd"
expect_status 0
expect_in "$work/out" "$work/results/UITests-iPhone-17-2-27.0.xcresult"
expect_in "$work/out" "$work/dd/UITests-iPhone-17-2-27.0"
run make -n -C "$root" test-ui DESTINATION="$oldest" TEST_RESULTS="$work/results" DERIVED_DATA="$work/dd"
expect_status 0
expect_in "$work/out" "$work/results/UITests-iPhone-15-17.5.xcresult"
expect_in "$work/out" "$work/dd/UITests-iPhone-15-17.5"

describe "one worker"
test_ui UI_TEST_WORKERS=1
expect_status 0
expect_in "$work/arguments" "-parallel-testing-enabled"
expect_equal "$(grep -A1 -e '-parallel-testing-enabled' "$work/arguments")" "-parallel-testing-enabled
NO"
expect_not_in "$work/arguments" "-parallel-testing-worker-count"
expect_equal "$(grep -A1 -e '-resultBundlePath' "$work/arguments")" "-resultBundlePath
$work/results/UITests-iPhone-17-2-27.0.xcresult"

describe "two workers on CI"
CI=true test_ui UI_TEST_WORKERS=2
expect_status 0
expect_equal "$(grep -A3 -e '-parallel-testing-enabled' "$work/arguments")" "-parallel-testing-enabled
YES
-parallel-testing-worker-count
2"

describe "two workers outside CI"
test_ui UI_TEST_WORKERS=2
expect_status 2
expect_in "$work/out" "test-ui: parallel workers clone simulators, which only CI may do (see AGENTS.md)"
expect_missing "$work/arguments"

for workers in 0 01 abc "" 100; do
	describe "UI_TEST_WORKERS='$workers'"
	CI=true test_ui UI_TEST_WORKERS="$workers"
	expect_status 2
	expect_in "$work/out" "test-ui: UI_TEST_WORKERS must be a number from 1 to 99, not '$workers'"
	expect_missing "$work/arguments"
done

finish
