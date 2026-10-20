#!/usr/bin/env bash
# The compiled metadata contract, including the static-package re-export that broke iOS 17 lookup.
. "$(dirname "$0")/lib.sh"

app="$work/CircuitTimer.app"
widget="$app/PlugIns/CircuitTimerWidgets.appex"
fixture() {
	for host in "$app" "$widget"; do
		mkdir -p "$host/Metadata.appintents"
		cp "$root/scripts/tests/fixtures/activity-intents/"* "$host/Metadata.appintents/"
	done
}

describe "both hosts expose hidden controls with their identity and execution policy"
fixture
run python3 "$root/scripts/check-activity-intents.py" "$app"
expect_status 0

describe "a static-package re-export fails before the iOS 17 runtime loses the actions"
printf '%s\n' '{"includes":["15WorkoutActivity0aB7IntentsV"]}' > "$app/Metadata.appintents/extract.packagedata"
run python3 "$root/scripts/check-activity-intents.py" "$app"
expect_status 1
expect_in "$work/out" "re-exports"

describe "missing extension metadata cannot pass because the app has the action"
fixture
printf '%s\n' '{"actions":{}}' > "$widget/Metadata.appintents/extract.actionsdata"
run python3 "$root/scripts/check-activity-intents.py" "$app"
expect_status 1
expect_in "$work/out" "CircuitTimerWidgets.appex"

describe "an incorrect execution policy cannot run a control in the wrong process"
fixture
python3 - "$app/Metadata.appintents/extract.actionsdata" <<'PYDATA'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["actions"]["PauseWorkoutIntent"]["allowedTargets"] = []
path.write_text(json.dumps(data))
PYDATA
run python3 "$root/scripts/check-activity-intents.py" "$app"
expect_status 1
expect_in "$work/out" "PauseWorkoutIntent.allowedTargets"

describe "a missing generation parameter cannot bypass the stale-card fence"
fixture
python3 - "$app/Metadata.appintents/extract.actionsdata" <<'PYDATA'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
action = data["actions"]["ResumeWorkoutIntent"]
action["parameters"] = [parameter for parameter in action["parameters"] if parameter["name"] != "generation"]
path.write_text(json.dumps(data))
PYDATA
run python3 "$root/scripts/check-activity-intents.py" "$app"
expect_status 1
expect_in "$work/out" "activityID and generation"

describe "malformed and missing metadata fail with a nonzero result"
for malformed in yes no; do
	fixture
	if [ "$malformed" = yes ]; then
		printf '%s\n' '{broken' > "$app/Metadata.appintents/extract.actionsdata"
	else
		rm "$app/Metadata.appintents/extract.actionsdata"
	fi
	run python3 "$root/scripts/check-activity-intents.py" "$app"
	expect_status 1
	expect_in "$work/out" "activity intents:"
done

finish
