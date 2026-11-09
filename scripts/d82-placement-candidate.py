#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared test 9 (D55): measure Mac's production streams with the shared detector, write the
results file, and run the shared oracle's check on it.

    python3 -I scripts/placement-measure.py MANIFEST RESULTS

MANIFEST comes from Tests/SharedPlacementTests: the vendored golden's folder, the mutant (or
null), Mac's placement literals, its wordMs values and offsetsAssumedZero flags, and the paths of
its production streams as float32 (little-endian, mono): rec16 per track (the 16 kHz recognizer
input on the session timeline), mix48 per session (the export mix before encoding) and playback
per track (frames at the track's own rate), or "refused". Every burst is found with
placement.onset at the golden's expected sample, as the golden's README prescribes; nothing here
decides where a burst should be.
"""
import array
import json
import subprocess
import sys
from pathlib import Path


def main(manifest_path, results_path):
    manifest = json.loads(Path(manifest_path).read_text())
    golden_dir = Path(manifest['golden'])
    sys.path.insert(0, str(golden_dir))
    import placement  # the vendored shared oracle: detector and checker

    golden = placement.golden_json()
    if manifest['mutant']:
        golden = placement.mutated(golden, manifest['mutant'])
    expected = placement.expected(golden)
    sessions = {s['id']: s for s in golden['sessions']}

    def stream(path):
        values = array.array('f')
        values.frombytes(Path(path).read_bytes())
        return values

    legs = {'placement': manifest['placement'], 'rec16': {}, 'wordMs': manifest['wordMs'], 'mix48': {}, 'playback': {},
            'offsetsAssumedZero': manifest['offsetsAssumedZero']}
    mixes = {}
    for key, want in expected.items():
        session_id, track_id = key.split('/')
        if key not in manifest['rec16']:
            continue  # a missing track fails in the checker, not here
        recognizer = stream(manifest['rec16'][key])
        legs['rec16'][key] = [placement.onset(recognizer, 16000, e) for e in want['rec16']['frames']]
        if session_id in manifest['mix48']:
            if session_id not in mixes:
                mixes[session_id] = stream(manifest['mix48'][session_id])
            mix = mixes[session_id]
            legs['mix48'][key] = [placement.onset(mix, 48000, e) for e in want['mix48']['frames']]
        played = manifest['playback'].get(key)
        if played == 'refused':
            legs['playback'][key] = 'refused'
        elif played is not None:
            # Where the golden expects a refusal, still measure where Mac played it (the check fails).
            track = next(t for t in sessions[session_id]['tracks'] if t['id'] == track_id)
            rate, at = played['rate'], track['startOffsetMs'] or 0
            frames = [placement.frame(at, rate) + ms * rate // 1000 for ms in track['burstsMs']]
            playback = stream(played['stream'])
            legs['playback'][key] = [placement.onset(playback, rate, e) for e in frames]
    results = {'vector': golden['vector'], 'protocolCommit': manifest['protocolCommit'], 'app': manifest['app'], 'legs': legs}
    Path(results_path).write_text(json.dumps(results, indent=1, sort_keys=True) + '\n')
    command = [sys.executable, '-I', str(golden_dir / 'placement.py'), 'check']
    if manifest['mutant']:
        command += ['--mutant', manifest['mutant']]
    check = subprocess.run(command + [str(results_path)], capture_output=True, text=True)
    print(check.stdout + check.stderr, end='')
    return check.returncode


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:3]))
