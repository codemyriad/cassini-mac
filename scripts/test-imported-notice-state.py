#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the production UI-state owner with a headless probe; no app or windows."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="cassini-import-notice-") as temporary:
    executable = Path(temporary) / "notice-proof"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macosx15.0" if os.uname().machine == "arm64" else "x86_64-apple-macosx15.0",
        str(root / "Cassini/Library/ImportedMeetingNotice.swift"),
        str(root / "Tests/ImportedMeetingNoticeStateProbe/main.swift"),
        "-o", str(executable),
    ], check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=20)
