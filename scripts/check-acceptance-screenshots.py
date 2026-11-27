#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify that beta 19 acceptance UI test runs attach every expected b19-* PNG."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import sys

EXPECTED_SCREENSHOTS = [
    "b19-d1196-needs-attention-light",
    "b19-item1-docked-light",
    "b19-item1-floating-light",
    "b19-item4-all-active-light",
    "b19-item4-all-inactive-light",
    "b19-item4-starred-active-light",
    "b19-item4-starred-inactive-light",
    "b19-item4-all-active-dark",
    "b19-item4-all-inactive-dark",
    "b19-item4-starred-active-dark",
    "b19-item4-starred-inactive-dark",
    "b19-item15-active-light",
    "b19-item15-inactive-light",
    "b19-item15-active-dark",
    "b19-item15-inactive-dark",
    "b19-item2-top-light",
    "b19-item2-top-dark",
    "b19-item3-alignment-light",
    "b19-item12-menu-open-light",
    "b19-item12-menu-open-dark",
    "b19-item17-1120x720-light",
    "b19-item17-1120x720-dark",
    "b19-item-list-guard-light",
    "b19-item5-6-closed-1120x720-light",
    "b19-item7-docked-light",
    "b19-item13-idle-light",
    "b19-item14-active-light",
    "b19-item14-inactive-light",
    "b19-item14-active-dark",
    "b19-item14-inactive-dark",
    "b19-sidebar-width-1120x720-light",
    "b19-item8-no-speakers-1120x720-light",
    "b19-item8-no-speakers-1120x720-dark",
    "b19-item9-rename-big-title-light",
    "b19-item10-1120x720-light",
    "b19-item10-1120x720-dark",
    "b19-item11-meeting-bg-1120x720-light",
    "b19-item11-recording-bg-1120x720-light",
    "b19-item18-recording-1120x720-light",
    "b19-item19-before-light",
    "b19-item19-banner-light",
]


def collect_entries(manifest):
    entries = []
    def visit(value):
        if isinstance(value, dict):
            if "exportedFileName" in value:
                entries.append(value)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(manifest)
    return entries


def verify(root: Path, expected: list[str]) -> list[str]:
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Missing manifest.json in {root}")
    manifest = json.loads(manifest_path.read_text())
    entries = collect_entries(manifest)
    missing = []
    for name in expected:
        matches = [
            entry for entry in entries
            if entry.get("suggestedHumanReadableName", "").startswith((name + ".", name + "_"))
            or entry.get("suggestedHumanReadableName") == name
        ]
        if not matches:
            missing.append(name)
            continue
        data = (root / matches[0]["exportedFileName"]).read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"Attachment {name} is not a valid PNG")
        width, height = struct.unpack(">II", data[16:24])
        if width < 320 or height < 320:
            raise ValueError(f"Attachment {name} is unexpectedly small: {width}x{height}")
    return missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments_dir", type=Path)
    parser.add_argument("--expected", nargs="*", default=EXPECTED_SCREENSHOTS)
    args = parser.parse_args(argv)
    missing = verify(args.attachments_dir, args.expected)
    if missing:
        print(f"Missing expected acceptance screenshots ({len(missing)}): {', '.join(missing)}", file=sys.stderr)
        return 1
    print(f"Verified {len(args.expected)} acceptance screenshots in {args.attachments_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
