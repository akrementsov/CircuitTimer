#!/usr/bin/env python3
"""Check the metadata used by the system to dispatch Live Activity buttons in either host."""

import argparse
import json
from pathlib import Path
import sys


def check_host(host):
    metadata = host / "Metadata.appintents"
    packages = json.loads((metadata / "extract.packagedata").read_text())
    if packages["includes"]:
        raise ValueError(f"{host.name} re-exports packages; WorkoutActivity metadata must be merged statically for iOS 17")

    actions = json.loads((metadata / "extract.actionsdata").read_text())["actions"]
    for name in ["PauseWorkoutIntent", "ResumeWorkoutIntent"]:
        action = actions.get(name)
        if action is None:
            raise ValueError(f"{host.name} has no {name} metadata")
        expected = {
            "fullyQualifiedTypeName": "WorkoutActivity." + name,
            "isDiscoverable": False,
            "openAppWhenRun": False,
            "authenticationPolicy": 0,
            "supportedModes": 1,
            "allowedTargets": [{"type": 1}],
        }
        for key, value in expected.items():
            if action.get(key) != value:
                raise ValueError(f"{host.name}: {name}.{key} is {action.get(key)!r}, expected {value!r}")
        if {parameter["name"] for parameter in action["parameters"]} != {"activityID", "generation"}:
            raise ValueError(f"{host.name}: {name} must carry activityID and generation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built CircuitTimer.app")
    args = parser.parse_args()
    try:
        check_host(args.app)
        check_host(args.app / "PlugIns/CircuitTimerWidgets.appex")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"activity intents: {error}", file=sys.stderr)
        return 1
    print("activity intents: OK (app and widget)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
