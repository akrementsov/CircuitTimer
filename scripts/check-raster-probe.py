#!/usr/bin/env python3
"""Validate the temporary primitive experiment without third-party image libraries."""
import hashlib
import itertools
import json
from pathlib import Path
import struct
import sys


def check(directory):
    report = json.loads((directory / "report.json").read_text())
    assert report["status"] == "complete", "Probe did not complete"
    expected = set(itertools.product(
        ("coreGraphics", "imageRenderer", "drawHierarchy", "layerRender"),
        ("rounded", "rectangle"), (False, True), ("integer", "half"), (1, 2),
    ))
    actual = set()
    for case in report["cases"]:
        key = (case["renderer"], case["shape"], case["antialias"], case["phase"], case["repeat"])
        assert key not in actual, f"Duplicate case: {key}"
        actual.add(key)
        identifier = f"{case['renderer']}-{case['shape']}-{'aa' if case['antialias'] else 'noaa'}-{case['phase']}-{case['repeat']}"
        assert case["id"] == identifier, f"Incorrect case identifier: {key}"
        png = (directory / (case["id"] + ".png")).read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {key}"
        assert struct.unpack(">II", png[16:24]) == (1206, 2622), f"Unexpected raster size: {key}"
        native = (directory / (case["id"] + ".native")).read_bytes()
        assert len(native) == 64 * 64 * (case["native"]["bitsPerPixel"] // 8), f"Truncated ROI: {key}"
        assert hashlib.sha256(native).hexdigest() == case["nativeSHA256"], f"Native ROI changed: {key}"
        background, center = case["validation"]["background"], case["validation"]["center"]
        assert background[3] == center[3] == 255, f"Transparent capture: {key}"
        assert center[1] > center[0] + 40 and center[2] > center[0] + 40, f"Missing marker: {key}"
        assert max(abs(a - b) for a, b in zip(background[:3], center[:3])) > 80, f"Blank capture: {key}"
        assert case["path"], f"Missing path commands: {key}"
    assert actual == expected, f"Incomplete matrix: missing={expected-actual}, extra={actual-expected}"
    print(f"raster-probe: {len(actual)} captures validated")


try:
    check(Path(sys.argv[1]))
except (AssertionError, OSError, ValueError, KeyError, IndexError, struct.error) as error:
    print(f"raster-probe: {error}", file=sys.stderr)
    sys.exit(1)
