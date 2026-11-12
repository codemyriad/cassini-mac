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


def parse_labels(raw):
    if not raw:
        return ()
    loaded = json.loads(raw)
    if loaded is None:
        return ()
    if not isinstance(loaded, list) or not all(isinstance(item, str) for item in loaded):
        raise ValueError(f'Expected JSON string list of labels, got {loaded!r}')
    return tuple(loaded)


def execution_tier(event, labels=()):
    if event == 'pull_request':
        label_set = {label.casefold() for label in labels}
        full_ci = 'full-ci' in label_set
        ui_shots = 'ui-shots' in label_set
        return {'full_ci': full_ci, 'ui_shots': ui_shots, 'release_build': full_ci}
    if event == 'push':
        return {'full_ci': False, 'ui_shots': True, 'release_build': True}
    return {'full_ci': True, 'ui_shots': False, 'release_build': True}


def select(event, base, paths, changed=None, labels=()):
    everything = dict.fromkeys(paths, True)
    label_set = {label.casefold() for label in labels}
    if event != 'pull_request' or not base or 'full-ci' in label_set:
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
        if 'ui-shots' in label_set and 'boards' in selected:
            selected['boards'] = True
        return selected
    except (OSError, UnicodeError, subprocess.SubprocessError, ValueError) as error:
        print('Path detection failed; running all UX checks:', error, file=sys.stderr)
        return everything


def main():
    paths = json.loads((ROOT/'.github/ci/paths.json').read_text())
    event = os.environ.get('EVENT_NAME')
    try:
        labels = parse_labels(os.environ.get('PR_LABELS'))
        result = {
            **select(event, os.environ.get('PR_BASE'), paths, labels=labels),
            **execution_tier(event, labels),
        }
    except ValueError as error:
        print('Label parsing failed; running full CI:', error, file=sys.stderr)
        result = {**dict.fromkeys(paths, True), 'full_ci': True, 'ui_shots': False, 'release_build': True}
    output = '\n'.join(f'{key}={str(value).lower()}' for key, value in result.items())+'\n'
    print(output, end='')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(output)


if __name__ == '__main__':
    main()
