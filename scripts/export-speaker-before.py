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
result = boards.export_boards(Path("build/ux-attachments"), target, Path("build/ux-attachments-dark"))
assert len(result["shots"]) == 2
(target / "before-source.json").write_text(json.dumps({
    "product_source": baseline,
    "capture_source": os.environ["GITHUB_SHA"],
    "run_id": os.environ["GITHUB_RUN_ID"],
    "purpose": "WP6 existing native speaker dialog; harness-only changes",
}, indent=2) + "\n")
