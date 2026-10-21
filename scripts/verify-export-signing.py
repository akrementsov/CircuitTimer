#!/usr/bin/env python3
"""Checks that a TestFlight build ships the app and its widget extension signed for App Store distribution.

The archive is signed only ad hoc, to carry the app's entitlements to the export, where an App Store Connect API key
signs it, so the App Store signatures and profiles exist only in what the export produced. Run with `python3 -I`; it
uses the standard library only.

  verify-export-signing.py archive <CircuitTimer.xcarchive>
      The app declares Live Activities, remote notifications and its CloudKit container, carries the container in
      its ad hoc signature and embeds the widget extension. Exit 0 or 1.
  verify-export-signing.py ipa <CircuitTimer.ipa> <team> <app id> <widgets id> <icloud container>
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


def check_cloudkit(name, entitlements, container):
    if entitlements.get("com.apple.developer.icloud-container-identifiers") != [container]:
        raise Mismatch(f"{name}: iCloud containers are "
                       f"{entitlements.get('com.apple.developer.icloud-container-identifiers')!r}, not {[container]!r}")
    if "CloudKit" not in entitlements.get("com.apple.developer.icloud-services", []):
        raise Mismatch(f"{name}: iCloud services {entitlements.get('com.apple.developer.icloud-services')!r} lack CloudKit")


def check_distribution_cloudkit(name, entitlements, profile, container):
    check_cloudkit(name, entitlements, container)
    if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
        raise Mismatch(f"{name}: the CloudKit environment is "
                       f"{entitlements.get('com.apple.developer.icloud-container-environment')!r}, not 'Production'")
    if entitlements.get("aps-environment") != "production":
        raise Mismatch(f"{name}: the push environment is {entitlements.get('aps-environment')!r}, not 'production'")
    allowed = profile.get("Entitlements", {}).get("com.apple.developer.icloud-container-identifiers", [])
    if container not in allowed:
        raise Mismatch(f"{name}: the profile allows the iCloud containers {allowed!r}, not {container!r}")


def run_plist(name, command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        raise Mismatch(f"{name}: {command[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    try:
        return plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        raise Mismatch(f"{name}: {command[0]} printed no property list, so the bundle has no such signature") from None


def signed_entitlements(bundle):
    return run_plist(bundle.name, ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)])


def verify_bundle(bundle, team, bundle_id, container=None):
    entitlements = signed_entitlements(bundle)
    check_entitlements(bundle.name, entitlements, team, bundle_id)
    profile = run_plist(bundle.name, ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")])
    if team not in profile.get("TeamIdentifier", []):
        raise Mismatch(f"{bundle.name}: the profile belongs to {profile.get('TeamIdentifier')}, not {team}")
    if "ProvisionedDevices" in profile:
        raise Mismatch(f"{bundle.name}: the profile lists devices, so it is not an App Store profile")
    if container is not None:
        check_distribution_cloudkit(bundle.name, entitlements, profile, container)
    print(f"{bundle.name}: signed for {entitlements['application-identifier']} with profile {profile.get('Name')!r}")


def verify_ipa(path, team, app_id, widgets_id, container):
    with tempfile.TemporaryDirectory() as directory:
        with zipfile.ZipFile(path) as ipa:
            ipa.extractall(directory)
        app = Path(directory) / "Payload" / APP
        verify_bundle(app, team, app_id, container)
        verify_bundle(app / "PlugIns" / WIDGETS, team, widgets_id)
    return 0


def verify_archive(path):
    app = Path(path) / "Products" / "Applications" / APP
    with open(app / "Info.plist", "rb") as file:
        info = plistlib.load(file)
    if info.get("NSSupportsLiveActivities") is not True:
        raise Mismatch(f"{APP}: NSSupportsLiveActivities is not set")
    if "remote-notification" not in info.get("UIBackgroundModes", []):
        raise Mismatch(f"{APP}: UIBackgroundModes {info.get('UIBackgroundModes')!r} lack remote-notification")
    container = info.get("CTCloudKitContainerIdentifier")
    if container != f"iCloud.{info.get('CFBundleIdentifier')}":
        raise Mismatch(f"{APP}: the CloudKit container is {container!r}, not iCloud.{info.get('CFBundleIdentifier')}")
    entitlements = signed_entitlements(app)
    check_cloudkit(APP, entitlements, container)
    if "aps-environment" not in entitlements:
        raise Mismatch(f"{APP}: the archived signature has no aps-environment")
    with open(app / "PlugIns" / WIDGETS / "Info.plist", "rb") as file:
        extension = plistlib.load(file).get("NSExtension", {})
    if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise Mismatch(f"{WIDGETS}: not a WidgetKit extension")
    print(f"{APP} declares Live Activities and {container}, carries its entitlements and embeds {WIDGETS}")
    return 0


def main(arguments):
    try:
        if len(arguments) == 2 and arguments[0] == "archive":
            return verify_archive(arguments[1])
        if len(arguments) == 6 and arguments[0] == "ipa":
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
