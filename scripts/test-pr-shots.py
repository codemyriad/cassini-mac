#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Contract and Mac integration tests for vendored scripts/pr-shots.py (W0.8)."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parent.parent
PR_SHOTS = ROOT / "scripts" / "pr-shots.py"
EXPORT_BOARDS = ROOT / "scripts" / "export-ux-boards.py"
EXPECTED_HEADER = (
    "# Vendored from codemyriad/cassini-ux@"
    "592f9cc6bd1cd1d3aac1beb63cb69ff199bd1d25:tools/pr-shots/pr-shots.py"
)
EXPECTED_CANONICAL_SHA256 = "63cc9e25f2583895b1f0d1a5befa2611e4271bf2cfa3b06b8c09bf95561afa65"

BOARDS_21 = (
    "library",
    "library-fr",
    "first-run",
    "first-run-fr",
    "record-first",
    "record-first-fr",
    "recording",
    "recording-details",
    "meeting",
    "received",
    "export",
    "export-success",
    "search",
    "rename",
    "trash",
    "trash-after",
    "trash-meeting",
    "companion-setup",
    "what-is-recorded",
    "settings-recording",
    "settings-transcription",
)
BOARDS_27 = BOARDS_21 + (
    "recording-details-many",
    "listening-bar-finished",
    "listening-transcript-highlight",
    "settings-parakeet-recommendation-en-GB",
    "settings-parakeet-recommendation-fr-FR",
    "settings-parakeet-recommendation-pt-PT",
)


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_png(width: int, height: int, rgba: tuple[int, int, int, int], text_note: str = "") -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    row = b"\x00" + bytes(rgba) * width
    # Repeat scanlines only for the first 4 rows and keep remaining rows uniform so 27*2 HD PNGs generate in <50 ms.
    raw = row * height
    extra = chunk(b"tEXt", b"Comment\x00" + text_note.encode("ascii")) if text_note else b""
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + extra
        + chunk(b"IDAT", zlib.compress(raw, level=1))
        + chunk(b"IEND", b"")
    )


class VendoredSourceContract(unittest.TestCase):
    def test_header_names_cassini_ux_commit_and_canonical_bytes_match(self) -> None:
        lines = PR_SHOTS.read_bytes().splitlines(keepends=True)
        self.assertEqual(lines[0], b"#!/usr/bin/env python3\n")
        self.assertEqual(lines[1].decode("utf-8").rstrip("\n"), EXPECTED_HEADER)
        canonical = lines[0] + b"".join(lines[2:])
        self.assertEqual(hashlib.sha256(canonical).hexdigest(), EXPECTED_CANONICAL_SHA256)
        self.assertTrue(os.access(PR_SHOTS, os.X_OK))


class MacScreenshotDiffIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.shots = load_module(PR_SHOTS, "pr_shots")
        cls.exporter = load_module(EXPORT_BOARDS, "export_ux_boards")
        cls.light_1120 = make_png(1120, 720, (244, 243, 238, 255), "encoder-a")
        cls.light_1120_reencoded = make_png(1120, 720, (244, 243, 238, 255), "encoder-b-different-bytes")
        cls.dark_1120 = make_png(1120, 720, (24, 26, 32, 255), "encoder-a")
        cls.light_700 = make_png(700, 560, (244, 243, 238, 255), "encoder-a")
        cls.light_700_reencoded = make_png(700, 560, (244, 243, 238, 255), "encoder-b-different-bytes")
        cls.dark_700 = make_png(700, 560, (24, 26, 32, 255), "encoder-a")

    def write_exported_boards(self, root: Path, reencoded: bool = False) -> Path:
        light_src = root / "att-light"
        dark_src = root / "att-dark"
        light_src.mkdir(parents=True)
        dark_src.mkdir(parents=True)
        manifest = []
        for idx, board in enumerate(BOARDS_27):
            is_settings = board.startswith("settings-")
            l_bytes = (
                (self.light_700_reencoded if is_settings else self.light_1120_reencoded)
                if reencoded
                else (self.light_700 if is_settings else self.light_1120)
            )
            d_bytes = self.dark_700 if is_settings else self.dark_1120
            l_file = f"{board}_0_{idx}.png"
            d_file = f"{board}_1_{idx}.png"
            (light_src / l_file).write_bytes(l_bytes)
            (dark_src / d_file).write_bytes(d_bytes)
            manifest.append(
                {
                    "testIdentifier": f"LibraryBoards/testBoard{idx}()",
                    "attachments": [{"exportedFileName": l_file, "suggestedHumanReadableName": f"{board}_0_{idx}.png"}],
                }
            )
        (light_src / "tree.txt").write_text("ax tree", encoding="utf-8")
        (light_src / "menu.json").write_text(
            json.dumps({"assertionHeld": True, "actions": [{"id": i} for i in ("stop", "open", "settings", "quit")]}),
            encoding="utf-8",
        )
        manifest.append(
            {
                "testIdentifier": "LibraryBoards/testExtras()",
                "attachments": [
                    {"exportedFileName": "tree.txt", "suggestedHumanReadableName": "meeting-accessibility-tree_0_u.txt"},
                    {"exportedFileName": "menu.json", "suggestedHumanReadableName": "recording-menu.json_0_u.json"},
                ],
            }
        )
        (light_src / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        dark_manifest = [
            {
                "testIdentifier": item["testIdentifier"],
                "attachments": [
                    {
                        "exportedFileName": item["attachments"][0]["exportedFileName"].replace("_0_", "_1_"),
                        "suggestedHumanReadableName": item["attachments"][0]["suggestedHumanReadableName"].replace(
                            "_0_", "_1_"
                        ),
                    }
                ],
            }
            for item in manifest[:-1]
        ]
        (dark_src / "manifest.json").write_text(json.dumps(dark_manifest), encoding="utf-8")
        out = root / "ux-boards"
        with patch.dict(os.environ, {"ImageOS": "macos15", "ImageVersion": "20261102.1"}), contextlib.redirect_stdout(
            io.StringIO()
        ):
            self.exporter.export_boards(light_src, out, dark_src)
        return out

    def test_isolated_self_test_with_unset_step_summary_leaves_outer_summary_clean(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            outer_summary = Path(tmp) / "step_summary.md"
            outer_summary.write_text("# Outer job summary\n", encoding="utf-8")
            env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
            res = subprocess.run(
                [sys.executable, "-I", str(PR_SHOTS), "--self-test"],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("pr-shots.py self-test passed", res.stdout)
            self.assertEqual(outer_summary.read_text(encoding="utf-8"), "# Outer job summary\n")

    def test_reencoded_identical_pixels_across_54_mac_boards_report_no_visual_change(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            before = self.write_exported_boards(work / "base", reencoded=False)
            after = self.write_exported_boards(work / "head", reencoded=True)
            self.assertNotEqual((before / "library.png").read_bytes(), (after / "library.png").read_bytes())
            out = work / "pr-shots"
            args = self.shots.parser().parse_args(
                [
                    "diff",
                    "--layout",
                    "mac",
                    "--repo",
                    "codemyriad/cassini-mac",
                    "--pr",
                    "266",
                    "--base-sha",
                    "a" * 40,
                    "--head-sha",
                    "b" * 40,
                    "--base-run",
                    "100",
                    "--head-run",
                    "200",
                    "--base-runner",
                    "macos-15",
                    "--head-runner",
                    "macos-15",
                    "--base-image",
                    "20261102.1",
                    "--head-image",
                    "20261102.1",
                    "--before-dir",
                    str(before),
                    "--after-dir",
                    str(after),
                    "--tolerance",
                    "6",
                    "--out",
                    str(out),
                ]
            )
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("GITHUB_STEP_SUMMARY", None)
                with contextlib.redirect_stdout(io.StringIO()):
                    data = self.shots.diff(args)
            self.assertEqual(len(data["rows"]), 54)
            self.assertTrue(all(r["status"] == "unchanged" for r in data["rows"]))
            self.assertIn("No visual change in 27 screens (light and dark).", (out / "block.md").read_text())
            self.assertEqual(list(out.rglob("*.png")), [])

    def test_single_changed_mac_board_emits_both_modes_and_downloadable_summary(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            before = self.write_exported_boards(work / "base", reencoded=False)
            after = self.write_exported_boards(work / "head", reencoded=False)
            with Image.open(after / "library.png") as im:
                edited = im.convert("RGBA")
            edited.putpixel((20, 20), (0, 99, 128, 255))
            edited.save(after / "library.png")

            out = work / "pr-shots"
            summary_file = work / "summary.md"
            args = self.shots.parser().parse_args(
                [
                    "diff",
                    "--layout",
                    "mac",
                    "--repo",
                    "codemyriad/cassini-mac",
                    "--pr",
                    "266",
                    "--base-sha",
                    "a" * 40,
                    "--head-sha",
                    "b" * 40,
                    "--base-run",
                    "100",
                    "--head-run",
                    "200",
                    "--base-runner",
                    "macos-15",
                    "--head-runner",
                    "macos-15",
                    "--base-image",
                    "20261102.1",
                    "--head-image",
                    "20261102.1",
                    "--before-dir",
                    str(before),
                    "--after-dir",
                    str(after),
                    "--tolerance",
                    "6",
                    "--out",
                    str(out),
                ]
            )
            with patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": str(summary_file), "GITHUB_RUN_ID": "43199999999"}
            ), contextlib.redirect_stdout(io.StringIO()):
                data = self.shots.diff(args)

            changed = [r for r in data["rows"] if r["status"] != "unchanged"]
            self.assertEqual([(r["screen"], r["scheme"], r["lang"]) for r in changed], [("library", "light", "en")])
            # Both light and dark of the changed screen are copied into before/, after/, and diff/.
            expected_pngs = {
                "before/library.light.png",
                "after/library.light.png",
                "diff/library.light.png",
                "before/library.dark.png",
                "after/library.dark.png",
                "diff/library.dark.png",
            }
            actual_pngs = {p.relative_to(out).as_posix() for p in out.rglob("*.png")}
            self.assertEqual(actual_pngs, expected_pngs)
            validated = self.shots.validated(
                data, self.shots.directory(out), "codemyriad/cassini-mac", 266, "b" * 40
            )
            self.assertEqual(set(validated), expected_pngs)

            summary_md = summary_file.read_text(encoding="utf-8")
            self.assertIn("1 screens changed, 26 unchanged.", summary_md)
            self.assertIn("Library · light", summary_md)
            self.assertIn("Library · dark", summary_md)
            self.assertIn("https://github.com/codemyriad/cassini-mac/actions/runs/43199999999#artifacts", summary_md)
            self.assertNotIn("/raw/pr-shots/", summary_md)
            self.assertIn("/raw/pr-shots/pr-266/bbbbbbb/", (out / "block.md").read_text(encoding="utf-8"))

    def test_missing_or_empty_after_directory_fails_non_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "empty"
            empty.mkdir()
            for candidate in (empty, Path(tmp) / "missing"):
                res = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        str(PR_SHOTS),
                        "diff",
                        "--layout",
                        "mac",
                        "--repo",
                        "codemyriad/cassini-mac",
                        "--pr",
                        "1",
                        "--base-sha",
                        "a" * 40,
                        "--head-sha",
                        "b" * 40,
                        "--after-dir",
                        str(candidate),
                        "--out",
                        str(Path(tmp) / "out"),
                    ],
                    env={k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"},
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
