#!/usr/bin/env python3
"""Checks that a TestFlight build ships the app and its widget extension signed for App Store distribution.

The archive is unsigned and an App Store Connect API key signs it at export, so the entitlements and profiles exist
only in what the export produced. Run with `python3 -I`; it uses the standard library only.

  verify-export-signing.py archive <CircuitTimer.xcarchive>
      The app declares Live Activities and embeds the widget extension. Exit 0 or 1.
  verify-export-signing.py summary <DistributionSummary.plist> <team> <app id> <widgets id>
      Exit 0 when both bundles are signed as expected, 1 on a mismatch, 2 when the summary does not say.
  verify-export-signing.py ipa <CircuitTimer.ipa> <team> <app id> <widgets id>
      Reads the signatures and profiles of an exported IPA. Exit 0 or 1.
"""

import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

APP = "CircuitTimer.app"
WIDGETS = "CircuitTimerWidgets.appex"


class Mismatch(Exception):
    pass


def check_entitlements(name, entitlements, team, bundle_id):
    if not isinstance(entitlements, dict):
        raise Mismatch(f"{name}: no entitlements")
    expected = f"{team}.{bundle_id}"
    if entitlements.get("application-identifier") != expected:
        raise Mismatch(f"{name}: application-identifier is {entitlements.get('application-identifier')!r}, not {expected!r}")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise Mismatch(f"{name}: team identifier is {entitlements.get('com.apple.developer.team-identifier')!r}, not {team!r}")
    if entitlements.get("get-task-allow") is True:
        raise Mismatch(f"{name}: get-task-allow is set, so this is a development signature")


def entries_named(node, names):
    """Every dictionary in the summary whose `name` is one of `names`, at any depth."""
    if isinstance(node, dict):
        if node.get("name") in names:
            yield node
        for value in node.values():
            yield from entries_named(value, names)
    elif isinstance(node, list):
        for value in node:
            yield from entries_named(value, names)


def verify_summary(path, team, app_id, widgets_id):
    try:
        with open(path, "rb") as file:
            summary = plistlib.load(file)
    except FileNotFoundError:
        print(f"{path} does not exist")
        return 2
    expected = {APP: app_id, WIDGETS: widgets_id}
    found = {}
    for entry in entries_named(summary, expected.keys()):
        found.setdefault(entry["name"], entry)
    missing = sorted(set(expected) - set(found))
    if missing:
        print(f"The summary does not list {', '.join(missing)}")
        return 2
    for name, entry in found.items():
        if "entitlements" not in entry:
            print(f"{name}: the summary shows no entitlements")
            return 2
        check_entitlements(name, entry["entitlements"], team, expected[name])
        if not entry.get("profile"):
            raise Mismatch(f"{name}: the summary shows no provisioning profile")
        print(f"{name}: signed for {entry['entitlements']['application-identifier']}")
    return 0


def run_plist(name, command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        raise Mismatch(f"{name}: {command[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    try:
        return plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        raise Mismatch(f"{name}: {command[0]} printed no property list, so the bundle has no such signature") from None


def verify_bundle(bundle, team, bundle_id):
    entitlements = run_plist(bundle.name, ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)])
    check_entitlements(bundle.name, entitlements, team, bundle_id)
    profile = run_plist(bundle.name, ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")])
    if team not in profile.get("TeamIdentifier", []):
        raise Mismatch(f"{bundle.name}: the profile belongs to {profile.get('TeamIdentifier')}, not {team}")
    if "ProvisionedDevices" in profile:
        raise Mismatch(f"{bundle.name}: the profile lists devices, so it is not an App Store profile")
    print(f"{bundle.name}: signed for {entitlements['application-identifier']} with profile {profile.get('Name')!r}")


def verify_ipa(path, team, app_id, widgets_id):
    with tempfile.TemporaryDirectory() as directory:
        with zipfile.ZipFile(path) as ipa:
            ipa.extractall(directory)
        app = Path(directory) / "Payload" / APP
        verify_bundle(app, team, app_id)
        verify_bundle(app / "PlugIns" / WIDGETS, team, widgets_id)
    return 0


def verify_archive(path):
    app = Path(path) / "Products" / "Applications" / APP
    with open(app / "Info.plist", "rb") as file:
        info = plistlib.load(file)
    if info.get("NSSupportsLiveActivities") is not True:
        raise Mismatch(f"{APP}: NSSupportsLiveActivities is not set")
    with open(app / "PlugIns" / WIDGETS / "Info.plist", "rb") as file:
        extension = plistlib.load(file).get("NSExtension", {})
    if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise Mismatch(f"{WIDGETS}: not a WidgetKit extension")
    print(f"{APP} declares Live Activities and embeds {WIDGETS}")
    return 0


def main(arguments):
    try:
        if len(arguments) == 2 and arguments[0] == "archive":
            return verify_archive(arguments[1])
        if len(arguments) == 5 and arguments[0] == "summary":
            return verify_summary(*arguments[1:])
        if len(arguments) == 5 and arguments[0] == "ipa":
            return verify_ipa(*arguments[1:])
    except Mismatch as mismatch:
        print(f"::error::{mismatch}")
        return 1
    except (OSError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print(f"::error::{error}")
        return 1
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
