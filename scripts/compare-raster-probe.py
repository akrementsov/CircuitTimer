#!/usr/bin/env python3
"""Compare native primitive ROIs across hosts, preserving format and input differences."""
import json
from pathlib import Path
import sys


def read(directory):
    report = json.loads((directory / "report.json").read_text())
    cases = {case["id"]: case for case in report["cases"]}
    assert report["status"] == "complete" and len(cases) == 64, "Incomplete probe"
    return report, cases


def difference(left_directory, left, right_directory, right):
    metadata = {key: [left[key], right[key]] for key in ("native", "path", "origin", "environment") if left[key] != right[key]}
    if left["native"] != right["native"]:
        return {"inputOrFormatDifferences": metadata, "differentPixels": None, "maxByteDelta": None, "points": []}
    a = (left_directory / (left["id"] + ".native")).read_bytes()
    b = (right_directory / (right["id"] + ".native")).read_bytes()
    stride = left["native"]["bitsPerPixel"] // 8
    assert len(a) == len(b) == 64 * 64 * stride
    changed, maximum, points = 0, 0, []
    for pixel in range(64 * 64):
        old, new = a[pixel * stride:(pixel + 1) * stride], b[pixel * stride:(pixel + 1) * stride]
        if old != new:
            changed += 1
            maximum = max(maximum, max(abs(x-y) for x, y in zip(old, new)))
            if len(points) < 20:
                points.append({"x": 114 + pixel % 64, "y": 2121 + pixel // 64, "leftBytes": list(old), "rightBytes": list(new)})
    return {"inputOrFormatDifferences": metadata, "differentPixels": changed,
            "maxByteDelta": maximum if left["native"]["bitsPerComponent"] == 8 else None, "points": points}


def compare(left_directory, right_directory, output):
    left_report, left = read(left_directory)
    right_report, right = read(right_directory)
    assert left.keys() == right.keys(), "Different case matrices"
    report = {"inputs": {key: [left_report[key], right_report[key]] for key in ("foreground", "background", "scale", "roi")
                         if left_report[key] != right_report[key]}, "cases": {}, "repeatDifferences": {}}
    for key in sorted(left):
        report["cases"][key] = difference(left_directory, left[key], right_directory, right[key])
    for name, directory, cases in (("left", left_directory, left), ("right", right_directory, right)):
        report["repeatDifferences"][name] = {
            key: difference(directory, case, directory, cases[key[:-1] + "2"])
            for key, case in cases.items() if case["repeat"] == 1
        }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print("Input color/viewport differences:", report["inputs"])
    for renderer in ("coreGraphics", "imageRenderer", "drawHierarchy", "layerRender"):
        rows = [row for key, row in report["cases"].items() if key.startswith(renderer + "-")]
        print(renderer, ":", sum(row["differentPixels"] != 0 for row in rows), "/", len(rows), "captures differ")


try:
    compare(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
except (AssertionError, OSError, ValueError, KeyError, IndexError) as error:
    print(f"raster-probe comparison: {error}", file=sys.stderr)
    sys.exit(1)
