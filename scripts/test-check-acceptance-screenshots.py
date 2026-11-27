#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for scripts/check-acceptance-screenshots.py."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("check_acceptance_screenshots", ROOT / "scripts/check-acceptance-screenshots.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def fake_png(width: int = 1120, height: int = 720) -> bytes:
    return b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + struct.pack(">II", width, height) + b"\x08\x06\x00\x00\x00"


class CheckAcceptanceScreenshotsTests(unittest.TestCase):
    def test_passes_when_all_expected_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            names = ["b19-item1-docked-light", "b19-item2-top-dark"]
            manifest = []
            for idx, name in enumerate(names):
                fname = f"shot-{idx}.png"
                (root / fname).write_bytes(fake_png())
                manifest.append({"suggestedHumanReadableName": f"{name}_0.png", "exportedFileName": fname})
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(MOD.verify(root, names), [])
            self.assertEqual(MOD.main([str(root), "--expected", *names]), 0)

    def test_fails_when_expected_screenshot_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "shot-0.png").write_bytes(fake_png())
            manifest = [{"suggestedHumanReadableName": "b19-item1-docked-light_0.png", "exportedFileName": "shot-0.png"}]
            (root / "manifest.json").write_text(json.dumps(manifest))
            missing = MOD.verify(root, ["b19-item1-docked-light", "b19-item2-top-dark"])
            self.assertEqual(missing, ["b19-item2-top-dark"])
            self.assertEqual(MOD.main([str(root), "--expected", "b19-item1-docked-light", "b19-item2-top-dark"]), 1)


if __name__ == "__main__":
    unittest.main()
