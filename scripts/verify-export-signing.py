#!/usr/bin/env python3
"""Checks that a TestFlight build ships the app, its widget extension and its watch app signed for App Store distribution.

The archive is signed only ad hoc, to carry the app's entitlements to the export, where an App Store Connect API key
signs it, so the App Store signatures and profiles exist only in what the export produced. Run with `python3 -I`; it
uses the standard library only.

  verify-export-signing.py archive <CircuitTimer.xcarchive>
      The app declares Live Activities, remote notifications, workout processing, both Health usage texts in English
      and Russian and its CloudKit container, carries the container and HealthKit in its ad hoc signature and embeds
      the widget extension and the watch app, whose companion is the app and whose version is the app's. Exit 0 or 1.
  verify-export-signing.py ipa <CircuitTimer.ipa> <team> <app id> <widgets id> <watch id> <icloud container>
      Reads the signatures and profiles of an exported IPA: only the app has HealthKit and iCloud. Exit 0 or 1.
"""

import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

APP = "CircuitTimer.app"
WIDGETS = "CircuitTimerWidgets.appex"
WATCH = "CircuitTimerWatch.app"
ICLOUD_CONTAINERS = "com.apple.developer.icloud-container-identifiers"
VERSION_KEYS = ("CFBundleShortVersionString", "CFBundleVersion")
HEALTHKIT = "com.apple.developer.healthkit"
HEALTH_TEXTS = ("NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription")
BACKGROUND_MODES = ("remote-notification", "workout-processing")


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


def check_health_texts(name, strings):
    for key in HEALTH_TEXTS:
        text = strings.get(key)
        if not isinstance(text, str) or not text.strip():
            raise Mismatch(f"{name}: {key} is {text!r}, not a text")


def check_healthkit(name, entitlements, profile, expected):
    if not expected:
        if HEALTHKIT in entitlements:
            raise Mismatch(f"{name}: the signature has HealthKit, which only the app needs")
        return
    if entitlements.get(HEALTHKIT) is not True:
        raise Mismatch(f"{name}: the signature has {HEALTHKIT} {entitlements.get(HEALTHKIT)!r}, not True")
    if profile.get("Entitlements", {}).get(HEALTHKIT) is not True:
        raise Mismatch(f"{name}: the profile does not allow HealthKit")


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


def verify_bundle(bundle, team, bundle_id, container=None, health=False):
    entitlements = signed_entitlements(bundle)
    check_entitlements(bundle.name, entitlements, team, bundle_id)
    profile = run_plist(bundle.name, ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")])
    if team not in profile.get("TeamIdentifier", []):
        raise Mismatch(f"{bundle.name}: the profile belongs to {profile.get('TeamIdentifier')}, not {team}")
    if "ProvisionedDevices" in profile:
        raise Mismatch(f"{bundle.name}: the profile lists devices, so it is not an App Store profile")
    if container is not None:
        check_distribution_cloudkit(bundle.name, entitlements, profile, container)
    elif ICLOUD_CONTAINERS in entitlements:
        raise Mismatch(f"{bundle.name}: the signature has iCloud, which only the app needs")
    check_healthkit(bundle.name, entitlements, profile, health)
    print(f"{bundle.name}: signed for {entitlements['application-identifier']} with profile {profile.get('Name')!r}")


def verify_ipa(path, team, app_id, widgets_id, watch_id, container):
    with tempfile.TemporaryDirectory() as directory:
        with zipfile.ZipFile(path) as ipa:
            ipa.extractall(directory)
        app = Path(directory) / "Payload" / APP
        verify_bundle(app, team, app_id, container, health=True)
        verify_bundle(app / "PlugIns" / WIDGETS, team, widgets_id)
        verify_bundle(app / "Watch" / WATCH, team, watch_id)
    return 0


def verify_archive(path):
    app = Path(path) / "Products" / "Applications" / APP
    with open(app / "Info.plist", "rb") as file:
        info = plistlib.load(file)
    if info.get("NSSupportsLiveActivities") is not True:
        raise Mismatch(f"{APP}: NSSupportsLiveActivities is not set")
    for mode in BACKGROUND_MODES:
        if mode not in info.get("UIBackgroundModes", []):
            raise Mismatch(f"{APP}: UIBackgroundModes {info.get('UIBackgroundModes')!r} lack {mode}")
    check_health_texts(APP, info)
    with open(app / "ru.lproj" / "InfoPlist.strings", "rb") as file:
        check_health_texts(f"{APP}/ru.lproj/InfoPlist.strings", plistlib.load(file))
    container = info.get("CTCloudKitContainerIdentifier")
    if container != f"iCloud.{info.get('CFBundleIdentifier')}":
        raise Mismatch(f"{APP}: the CloudKit container is {container!r}, not iCloud.{info.get('CFBundleIdentifier')}")
    entitlements = signed_entitlements(app)
    check_cloudkit(APP, entitlements, container)
    if "aps-environment" not in entitlements:
        raise Mismatch(f"{APP}: the archived signature has no aps-environment")
    if entitlements.get(HEALTHKIT) is not True:
        raise Mismatch(f"{APP}: the archived signature has {HEALTHKIT} {entitlements.get(HEALTHKIT)!r}, not True")
    with open(app / "PlugIns" / WIDGETS / "Info.plist", "rb") as file:
        extension = plistlib.load(file).get("NSExtension", {})
    if extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise Mismatch(f"{WIDGETS}: not a WidgetKit extension")
    check_watch(app, info)
    print(f"{APP} declares Live Activities, workout processing and {container}, carries its entitlements and embeds "
          f"{WIDGETS} and {WATCH}")
    return 0


def check_watch(app, info):
    with open(app / "Watch" / WATCH / "Info.plist", "rb") as file:
        watch = plistlib.load(file)
    if watch.get("WKApplication") is not True:
        raise Mismatch(f"{WATCH}: WKApplication is {watch.get('WKApplication')!r}, not True")
    if watch.get("WKCompanionAppBundleIdentifier") != info.get("CFBundleIdentifier"):
        raise Mismatch(f"{WATCH}: the companion is {watch.get('WKCompanionAppBundleIdentifier')!r}, "
                       f"not {info.get('CFBundleIdentifier')!r}")
    for key in VERSION_KEYS:
        if watch.get(key) != info.get(key):
            raise Mismatch(f"{WATCH}: {key} is {watch.get(key)!r}, not the app's {info.get(key)!r}")


def main(arguments):
    try:
        if len(arguments) == 2 and arguments[0] == "archive":
            return verify_archive(arguments[1])
        if len(arguments) == 7 and arguments[0] == "ipa":
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
