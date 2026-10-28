#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Original PR path filters; unknown base or failed detection runs every UX area."""
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def select(event, base, paths, changed=None):
    everything = dict.fromkeys(paths, True)
    if event != 'pull_request' or not base:
        return everything
    try:
        if changed is None:
            changed = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', base+'...HEAD'], cwd=ROOT).decode().rstrip('\0').split('\0')
        # Workflow/build changes and shared scripts can affect every consumer.
        if any(p.startswith(('.github/', 'scripts/ci-')) for p in changed):
            return everything
        selected = {area: any(fnmatch.fnmatchcase(name, pattern) for name in changed for pattern in patterns)
                    for area, patterns in paths.items()}
        # Swift package dependencies feed the app as well as the unit tests.
        if any(p.startswith(('Sources/', 'Tests/', 'QuickLook/', 'Whistle/', 'Opus/', 'Parakeet/', 'ModelDownloads/')) or p in ('Package.swift', 'Package.resolved') for p in changed):
            return everything
        return selected
    except (OSError, UnicodeError, subprocess.SubprocessError, ValueError) as error:
        print('Path detection failed; running all UX checks:', error, file=sys.stderr)
        return everything


def main():
    paths = json.loads((ROOT/'.github/ci/paths.json').read_text())
    result = select(os.environ.get('EVENT_NAME'), os.environ.get('PR_BASE'), paths)
    output = '\n'.join(f'{key}={str(value).lower()}' for key,value in result.items())+'\n'
    print(output, end='')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(output)


if __name__ == '__main__':
    main()
