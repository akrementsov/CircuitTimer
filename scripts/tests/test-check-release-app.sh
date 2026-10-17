#!/usr/bin/env bash
# Tests `make check-release-app` on archives made of a few files. Make exits 2 when the recipe fails.
. "$(dirname "$0")/lib.sh"

# archive NAME: an archived app with a binary and a framework that name nothing of the UI tests.
archive() {
	app="$work/$1.xcarchive/Products/Applications/CircuitTimer.app"
	mkdir -p "$app/Frameworks/Kit.framework"
	printf '\000\000CircuitTimer main\000\000' > "$app/CircuitTimer"
	printf '\000\000WorkoutDomain Workout\000\000' > "$app/Frameworks/Kit.framework/Kit"
	printf '<plist><string>CircuitTimer</string></plist>' > "$app/Info.plist"
}

check() {
	run make -s -C "$root" check-release-app ARCHIVE_PATH="$work/$1.xcarchive"
}

describe "clean app"
archive clean
check clean
expect_status 0
expect_in "$work/out" "check-release-app: OK"

number=0
while IFS= read -r marker; do
	number=$((number + 1))
	describe "app naming $marker"
	archive "marker$number"
	printf '\000\000prefix %s suffix\000\000' "$marker" > "$app/Frameworks/Kit.framework/Kit"
	check "marker$number"
	expect_status 2
	expect_in "$work/out" "check-release-app: UI test scenarios reached the Release app in:"
	expect_in "$work/out" "$app/Frameworks/Kit.framework/Kit"
	expect_not_in "$work/out" "$app/CircuitTimer"
done <<'EOF'
AppScenario
AppScenarios
ScenarioLaunch
ScenarioFixture
CT_APP_SCENARIO
Leg day
EOF

describe "no archive"
check missing
expect_status 2
expect_in "$work/out" "check-release-app: no archived app at $work/missing.xcarchive/Products/Applications/CircuitTimer.app; run make archive first"

finish
