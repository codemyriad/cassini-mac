#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Focused WP6 before proof; this evidence branch has no production changes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess

baseline = "0e283ceb66fb49c6fcde617415f203ed55105342"
assert os.environ["GITHUB_REF_NAME"] == "evidence/wp6-speaker-before"
subprocess.run(["git", "diff", "--exit-code", baseline, "HEAD", "--", "Cassini", "Sources", "Components",
                "Package.swift", "project.yml", "Cassini.xcodeproj"], check=True)
spec = importlib.util.spec_from_file_location("boards", Path(__file__).with_name("export-ux-boards.py"))
boards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boards)
# This workflow captures one declared state; preserve the normal exporter's
# image, size, light/dark, pairing and manifest validation for that state.
boards.EXPECTED_BOARDS = frozenset(("speaker-editor",))
target = Path("build/ux-boards")
target.mkdir(parents=True, exist_ok=True)
light, rows = boards.export_scheme(Path("build/ux-attachments"), target, "light")
dark, dark_rows = boards.export_scheme(Path("build/ux-attachments-dark"), target, "dark")
rows.extend(dark_rows)
boards.verify_manifest_and_pixels(rows, light, dark, require_dark=True)
assert len(rows) == 2
result = {"version": 1, "app": "mac", "runner": boards.runner_info(), "shots": rows}
(target / "shots.json").write_text(json.dumps(result, indent=2) + "\n")
(target / "before-source.json").write_text(json.dumps({
    "product_source": baseline,
    "capture_source": os.environ["GITHUB_SHA"],
    "run_id": os.environ["GITHUB_RUN_ID"],
    "purpose": "WP6 existing native speaker dialog; harness-only changes",
}, indent=2) + "\n")
