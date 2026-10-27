#!/usr/bin/env python3
"""Fail even if XCTest was skipped: require two named window PNG attachments."""
import json
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
# Traverse xcresulttool's manifest without depending on optional schema fields.
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
for name in ("current-window", "current-window-sheet"):
    matches = [entry for entry in entries if entry.get("suggestedHumanReadableName", "").startswith((name + ".", name + "_"))
               or entry.get("suggestedHumanReadableName") == name]
    assert len(matches) == 1, (name, entries)
    data = (root / matches[0]["exportedFileName"]).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", name
    width, height = struct.unpack(">II", data[16:24])
    # Retina scale is allowed; titlebar and attached sheet stay in the window.
    if len(sys.argv) == 3:
        expected = tuple(map(int, sys.argv[2].split("x")))
        assert (width, height) == expected, (name, width, height, expected)
    else:
        assert width >= 960 and height >= 640, (name, width, height)
    print(f"{name}: {width}×{height}, {len(data)} bytes")
