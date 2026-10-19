#!/usr/bin/env python3
"""Validate the temporary primitive experiment without third-party image libraries."""
import hashlib
import itertools
import json
from pathlib import Path
import struct
import sys


def check(directory, allow_partial=False):
    report = json.loads((directory / "report.json").read_text())
    failures = report.get("failures", [])
    assert report["status"] == ("partial" if failures else "complete"), "Inconsistent completion status"
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
    identifiers = {f"{r}-{s}-{'aa' if a else 'noaa'}-{p}-{n}" for r, s, a, p, n in expected}
    successful = {case["id"] for case in report["cases"]}
    failed = {case["id"] for case in failures}
    assert len(failed) == len(failures), "Duplicate failure identifiers"
    assert not successful & failed, "Capture marked both successful and failed"
    assert actual <= expected and successful | failed == identifiers, "Incomplete capture attempts"
    assert all(case.get("error") for case in failures), "Missing failure description"
    assert allow_partial or not failures, f"Probe incomplete: {len(successful)} captures, {len(failed)} failures"
    print(f"raster-probe: {len(actual)} captures validated, {len(failed)} explicit failures")


try:
    assert len(sys.argv) in (2, 3) and (len(sys.argv) == 2 or sys.argv[2] == "--allow-partial"), "Invalid arguments"
    check(Path(sys.argv[1]), allow_partial=len(sys.argv) == 3)
except (AssertionError, OSError, ValueError, KeyError, IndexError, struct.error) as error:
    print(f"raster-probe: {error}", file=sys.stderr)
    sys.exit(1)
