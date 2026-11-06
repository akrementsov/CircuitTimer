#!/usr/bin/env python3
"""Fails when an asset that mirrors the `Brand` colour token differs from it, a copy of the launch logo or of the app
icon from its original, or the app icon is not an opaque 1024 px PNG.

AGENTS.md (core rule 3) keeps one universal value per colour, and the app's and the watch app's `AccentColor` repeat
`Brand`; DesignSystem's `AppLogo.svg` is a byte-for-byte copy of the launch screen's `LaunchLogo.svg`, and the watch
app's `AppIcon.png` of the app's, which App Store Connect takes only as 1024×1024 without alpha (8-bit RGB here). Each must hold exactly one universal colour without appearances, in the same colour space, and every
component must match `Brand`'s on the 0–255 scale: Xcode writes a component as a fraction ("0.906"), as hex ("0xE7")
or as an integer ("231"). Run with `python3 -I`; it uses the standard library only and finds the repository from its
own place.
"""

import json
import sys
from pathlib import Path

BRAND = "CircuitTimerKit/Sources/DesignSystem/Resources/Colors.xcassets/Brand.colorset/Contents.json"
MIRRORS = (
    "CircuitTimer/Assets.xcassets/AccentColor.colorset/Contents.json",
    "CircuitTimerWatch/Assets.xcassets/AccentColor.colorset/Contents.json",
)
COMPONENTS = ("red", "green", "blue", "alpha")
LOGO = "CircuitTimer/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg"
LOGO_COPIES = ("CircuitTimerKit/Sources/DesignSystem/Resources/Images.xcassets/AppLogo.imageset/AppLogo.svg",)
ICON = "CircuitTimer/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ICON_COPIES = ("CircuitTimerWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png",)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICON_SIZE = 1024
RGB = 2


class Mismatch(Exception):
    pass


def eight_bit(path, name, text):
    try:
        if text.lower().startswith("0x"):
            value = int(text, 16)
        elif "." in text:
            value = round(float(text) * 255)
        else:
            value = int(text)
    except ValueError:
        raise Mismatch(f"{path}: {name} is {text!r}, not a colour component") from None
    if not 0 <= value <= 255:
        raise Mismatch(f"{path}: {name} is {text!r}, outside 0–255")
    return value


def colour(root, path):
    try:
        with open(root / path, encoding="utf-8") as file:
            colors = json.load(file).get("colors")
    except (OSError, ValueError) as error:
        raise Mismatch(f"{path}: {error}") from None
    if not isinstance(colors, list) or len(colors) != 1:
        raise Mismatch(f"{path}: holds {len(colors) if isinstance(colors, list) else 'no'} colours, not one")
    entry = colors[0]
    if entry.get("idiom") != "universal" or "appearances" in entry:
        raise Mismatch(f"{path}: its colour is not one universal value")
    value = entry.get("color", {})
    components = value.get("components", {})
    return value.get("color-space"), tuple(eight_bit(path, name, str(components.get(name))) for name in COMPONENTS)


def icon_header(data):
    """Returns the width, height, bit depth and colour type of a PNG's IHDR chunk, or None."""
    if len(data) < 26 or not data.startswith(PNG_SIGNATURE) or data[12:16] != b"IHDR":
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"), data[24], data[25]


def copies(root, original, paths, failures):
    """Reads ORIGINAL and adds a failure for each of PATHS that is missing or not a byte-for-byte copy of it."""
    try:
        data = (root / original).read_bytes()
    except OSError as error:
        failures.append(f"{original}: {error}")
        data = None
    for path in paths:
        try:
            copy = (root / path).read_bytes()
        except OSError as error:
            failures.append(f"{path}: {error}")
            continue
        if data is not None and copy != data:
            failures.append(f"{path}: not an exact copy of {original}; change them together (AGENTS.md, core rule 3)")
    return data


def main(root):
    failures = []
    try:
        brand = colour(root, BRAND)
    except Mismatch as mismatch:
        print(f"check-brand-colors: {mismatch}", file=sys.stderr)
        return 1
    for path in MIRRORS:
        try:
            mirror = colour(root, path)
        except Mismatch as mismatch:
            failures.append(str(mismatch))
            continue
        if mirror != brand:
            failures.append(f"{path}: {mirror[0]} {mirror[1]} (red, green, blue, alpha), not Brand's {brand[0]} "
                            f"{brand[1]}; change them together (AGENTS.md, core rule 3)")
    copies(root, LOGO, LOGO_COPIES, failures)
    icon = copies(root, ICON, ICON_COPIES, failures)
    if icon is not None and icon_header(icon) != (ICON_SIZE, ICON_SIZE, 8, RGB):
        failures.append(f"{ICON}: IHDR {icon_header(icon)} (width, height, bit depth, colour type), not an opaque "
                        f"{ICON_SIZE} px 8-bit RGB PNG, which App Store Connect requires")
    for failure in failures:
        print(f"check-brand-colors: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parent.parent))
