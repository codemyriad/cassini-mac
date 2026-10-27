#!/usr/bin/env python3
"""Select a listed 1× mode for board screenshots, on an ephemeral hosted runner only.

Uses displayplacer's documented `list` and `id:... mode:...` interface. Refuses
fallbacks that do not actually take effect. No screen capture or TCC API is used.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time

if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Display mode changes are restricted to GitHub-hosted Actions")

root = Path("build")
root.mkdir(exist_ok=True)


def listing(name):
    output = subprocess.check_output(["displayplacer", "list"], text=True, timeout=20)
    print(output, flush=True)
    (root / name).write_text(output)
    return output


def main_display(output):
    displays = re.split(r"(?=Persistent screen id:)", output)
    matches = [d for d in displays if " - main display" in d and "Persistent screen id:" in d]
    if len(matches) != 1:
        raise SystemExit("Expected exactly one listed main display")
    return matches[0]


before = main_display(listing("display-before.txt"))
display_id = re.search(r"Persistent screen id: (\S+)", before)[1]
modes = []
for line in before.splitlines():
    match = re.search(r"mode (\d+): res:(\d+)x(\d+)", line)
    if not match or "scaling:on" in line:
        continue
    mode, width, height = map(int, match.groups())
    if width >= 1280 and height >= 900:
        modes.append((width * height, width, height, mode))
if not modes:
    raise SystemExit("No listed unscaled mode large enough for a 1120×720 window")
_, width, height, mode = min(modes)
selection = {"displayId": display_id, "mode": mode, "width": width, "height": height,
             "runnerImage": os.environ.get("ImageVersion"), "runnerName": os.environ.get("RUNNER_NAME")}
(root / "display-selection.json").write_text(json.dumps(selection, indent=2) + "\n")
print("Selecting", selection, flush=True)
subprocess.run(["displayplacer", f"id:{display_id} mode:{mode}"], check=True, timeout=20)
# The command can silently fall back to a different mode; verify readback.
for attempt in range(10):
    after = main_display(listing("display-after.txt"))
    actual = re.search(r"^Resolution: (\d+)x(\d+)$", after, re.MULTILINE)
    if actual and tuple(map(int, actual.groups())) == (width, height) and "Scaling: off" in after:
        print(f"Verified unscaled hosted display: {width}×{height}", flush=True)
        break
    time.sleep(0.3)
else:
    raise SystemExit("Selected display mode did not take effect")
