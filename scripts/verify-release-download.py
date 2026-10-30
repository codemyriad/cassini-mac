#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only HTTPS verification before publishing Cassini-talk.dmg and the appcast."""
import argparse
import json
from pathlib import Path
import subprocess
import release

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='Completed local release directory')
    args = parser.parse_args()
    try:
        print(json.dumps(release.verify_uploaded_download(args.output), indent=2))
    except (ValueError, RuntimeError, OSError, KeyError, TypeError, subprocess.TimeoutExpired):
        parser.exit(1, 'HTTPS verification failed. Do not publish the latest copy or appcast.\n')
