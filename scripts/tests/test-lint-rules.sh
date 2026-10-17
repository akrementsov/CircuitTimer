#!/usr/bin/env bash
# Tests the custom SwiftLint rules of the UI tests and of accessibility identifiers with the repository's
# configuration. Every line a rule must flag ends in `// expect: <rule>`, and no other line may be flagged; each line
# breaks one rule once. The files live in the repository, because CI's SwiftLint runs in Docker, which mounts only
# the repository, and SwiftLint passes a run that lints no file.
SCRATCH_IN_REPO=1 . "$(dirname "$0")/lib.sh"

swiftlint=${SWIFTLINT:-swiftlint}
rules='accessibility_identifier_constant|ui_test_no_sleep|ui_test_waits_in_screens|ui_test_launch_only'

mkdir -p "$work/CircuitTimerUITests/Screens" "$work/CircuitTimerUITests/Support" "$work/Sources/ProbeFeature"

cat > "$work/CircuitTimerUITests/ProbeUITests.swift" <<'EOF'
import XCTest

final class ProbeUITests: XCTestCase {
    func test_probe() {
        let app = XCUIApplication() // expect: ui_test_launch_only
        _ = XCUIApplication(bundleIdentifier: "com.apple.springboard") // expect: ui_test_launch_only
        _ = XCUIApplication.init() // expect: ui_test_launch_only
        let other: XCUIApplication = .init() // expect: ui_test_launch_only
        sleep(1) // expect: ui_test_no_sleep
        usleep(1) // expect: ui_test_no_sleep
        Thread.sleep(forTimeInterval: 1) // expect: ui_test_no_sleep
        _ = app.buttons["a"].waitForExistence(timeout: 1) // expect: ui_test_waits_in_screens
        _ = app.buttons["a"].waitForNonExistence(timeout: 1) // expect: ui_test_waits_in_screens
        _ = other.wait(for: .runningForeground, timeout: 1) // expect: ui_test_waits_in_screens
        let waiter = XCTWaiter() // expect: ui_test_waits_in_screens
        let predicate = NSPredicate(value: true)
        let shown = XCTNSPredicateExpectation(predicate: predicate, object: nil) // expect: ui_test_waits_in_screens
        let exists = expectation(for: predicate, evaluatedWith: app) // expect: ui_test_waits_in_screens
        wait(for: [exists, shown], timeout: 1) // expect: ui_test_waits_in_screens
        waitForExpectations(timeout: 1) // expect: ui_test_waits_in_screens
        _ = waiter
    }

    func test_probeAsync() async {
        let done = expectation(description: "done") // expect: ui_test_waits_in_screens
        await fulfillment(of: [done], timeout: 1) // expect: ui_test_waits_in_screens
    }

    func test_allowed() {
        sleepless()
        _ = expectationCount
        // sleep(1), XCUIApplication() and wait(for: [x], timeout: 1) in a comment
        _ = "sleep(1), XCUIApplication() and wait(for: [x], timeout: 1) in a string"
    }
}
EOF

cat > "$work/CircuitTimerUITests/Support/Launch.swift" <<'EOF'
import XCTest

func launch() -> XCUIApplication {
    let app = XCUIApplication()
    _ = XCUIApplication.init()
    _ = app.wait(for: .runningForeground, timeout: 1)
    return app
}
EOF

cat > "$work/CircuitTimerUITests/Support/Waiting.swift" <<'EOF'
import XCTest

extension XCUIElement {
    func waitUntilHittable() -> Bool {
        _ = waitForExistence(timeout: 1)
        _ = waitForNonExistence(timeout: 1)
        return wait(for: \.isHittable, toEqual: true, timeout: 1)
    }
}
EOF

cat > "$work/CircuitTimerUITests/Screens/ProbeScreen.swift" <<'EOF'
import XCTest

struct ProbeScreen {
    let app: XCUIApplication

    func waitForAlert(_ test: XCTestCase) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(value: true), object: app.alerts.firstMatch)
        let exists = test.expectation(for: NSPredicate(value: true), evaluatedWith: app)
        _ = XCTWaiter().wait(for: [shown, exists], timeout: 1)
    }
}
EOF

cat > "$work/Sources/ProbeFeature/ProbeView.swift" <<'EOF'
import SwiftUI

struct ProbeView: View {
    let identifier: String

    var body: some View {
        Text("a").accessibilityIdentifier("literal") // expect: accessibility_identifier_constant
        Text("b").accessibilityIdentifier(identifier) // expect: accessibility_identifier_constant
        Text("c").accessibilityIdentifier(AccessibilityID.Editor.save)
        Text("d").accessibilityIdentifier( AccessibilityID.Editor.back)
    }

    func outsideUITests() {
        sleep(1)
        _ = XCUIApplication()
    }
}
EOF

files=$(find "$work" -name '*.swift' | sort)
file_count=$(echo "$files" | wc -l | tr -d ' ')
expected=$(for file in $files; do
	grep -n '// expect: ' "$file" | sed -E "s|^([0-9]+):.*// expect: ([a-z_]+)\$|$file:\\1 \\2|"
done | sort)

describe "custom rules"
cd "$root"
# The repository's configuration excludes the scratch folder, so `make lint` never reads these files. A copy next to
# them, where that exclusion names a folder that does not exist, lints them by the same rules.
cp .swiftlint.yml "$work/swiftlint.yml"
# SWIFTLINT may be a command line with arguments, such as CI's `docker run`. Violations go to stdout and progress to
# stderr; Docker can interleave the two mid-line, so they are read apart.
set +e
$swiftlint lint --strict --config "$work/swiftlint.yml" $files > "$work/violations" 2> "$work/progress"
set -e
actual=$(sed -nE "s/^(.*):([0-9]+):[0-9]+: (error|warning): .* \\(($rules)\\)\$/\\1:\\2 \\4/p" "$work/violations" | sort)
expect_equal "$actual" "$expected"
expect_in "$work/progress" "in $file_count files."

finish
