#!/usr/bin/env python3
"""Fails when an asset that mirrors the `Brand` colour token differs from it.

AGENTS.md (core rule 3) keeps one universal value per colour, and the app's and the watch app's `AccentColor` repeat
`Brand`. Each must hold exactly one universal colour without appearances, in the same colour space, and every
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
    for failure in failures:
        print(f"check-brand-colors: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parent.parent))
