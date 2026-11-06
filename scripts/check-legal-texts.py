#!/usr/bin/env python3
"""Fails when a legal text the app bundles is not a byte-for-byte copy of its original in `docs/legal`, or an original
uses Markdown the app does not draw.

`docs/legal` holds the Privacy Policy and the Terms of Use in English and Russian; GitHub Pages publishes them, and
SettingsFeature bundles copies that `LegalText` draws (AGENTS.md › Localization). It knows Jekyll front matter, one `#`
title, `##` headings, `- ` bullets and paragraphs with inline links and bold, so any other block, such as `###`, a
numbered list or a quote, would show its marks in the app. Run with `python3 -I`; it uses the standard library only and
finds the repository from its own place.
"""

import re
import sys
from pathlib import Path

RESOURCES = "CircuitTimerKit/Sources/SettingsFeature/Resources"
TEXTS = (
    ("docs/legal/privacy-policy.md", f"{RESOURCES}/en.lproj/PrivacyPolicy.md"),
    ("docs/legal/terms-of-use.md", f"{RESOURCES}/en.lproj/TermsOfUse.md"),
    ("docs/legal/ru/privacy-policy.md", f"{RESOURCES}/ru.lproj/PrivacyPolicy.md"),
    ("docs/legal/ru/terms-of-use.md", f"{RESOURCES}/ru.lproj/TermsOfUse.md"),
)
HEADING = re.compile(r"#{1,2} \S")
# Block marks `LegalText` does not draw: deeper headings, other bullets, numbered lists, quotes, tables, code, HTML.
UNSUPPORTED = re.compile(r"#|[*+] |\d+[.)] |>|\||```|~~~|<|    |\t")


def syntax(path, text, failures):
    """Adds a failure for each line of TEXT outside the subset `LegalText` draws."""
    lines = text.split("\n")
    start = 0
    if lines and lines[0] == "---":
        end = next((index for index in range(1, len(lines)) if lines[index] == "---"), None)
        if end is None:
            failures.append(f"{path}:1: front matter without its closing ---")
            return
        start = end + 1
    for number, line in enumerate(lines[start:], start=start + 1):
        if line.startswith("#"):
            if not HEADING.match(line):
                failures.append(f"{path}:{number}: only # and ## headings are drawn in the app: {line!r}")
        elif line.startswith("-"):
            if not line.startswith("- "):
                failures.append(f"{path}:{number}: only '- ' bullets are drawn in the app: {line!r}")
        elif UNSUPPORTED.match(line):
            failures.append(f"{path}:{number}: Markdown the app does not draw: {line!r}")


def main(root):
    failures = []
    for original, copy in TEXTS:
        try:
            data = (root / original).read_bytes()
        except OSError as error:
            failures.append(f"{original}: {error}")
            data = None
        try:
            bundled = (root / copy).read_bytes()
        except OSError as error:
            failures.append(f"{copy}: {error}")
            bundled = None
        if data is None:
            continue
        try:
            syntax(original, data.decode("utf-8"), failures)
        except UnicodeDecodeError as error:
            failures.append(f"{original}: not UTF-8: {error}")
        if bundled is not None and bundled != data:
            failures.append(f"{copy}: not an exact copy of {original}; change them together (AGENTS.md › Localization)")
    for failure in failures:
        print(f"check-legal-texts: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parent.parent))
