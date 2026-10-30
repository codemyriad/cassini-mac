#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-only production native-view A–E spectrogram measurements, no devices."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def run(app: Path, output: Path):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise SystemExit('This view/display-link probe requires a disposable GitHub-hosted Mac')
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    problems = []
    for case in 'ABCDE':
        env = dict(os.environ, CASSINI_SPECTRO='0' if case == 'E' else '1')
        command = [str(app.resolve()/'Contents/MacOS/Cassini'), '--spectrogram-self-test',
                   '-SpectrogramCase', case, '-ApplePersistenceIgnoreState', 'YES']
        trace = None
        with (output/f'{case}.stderr.txt').open('w') as stderr, (output/f'{case}.top.txt').open('w') as top_log:
            process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=stderr, text=True)
            top = subprocess.Popen(['/usr/bin/top', '-l', '90', '-s', '1', '-pid', str(process.pid),
                                    '-stats', 'pid,cpu'], stdout=top_log, stderr=subprocess.STDOUT)
            try:
                if case == 'B':
                    trace = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                                              '--attach', str(process.pid), '--time-limit', '60s',
                                              '--output', str(output/'B-TimeProfiler.trace')],
                                             stdout=stderr, stderr=subprocess.STDOUT)
                stdout, _ = process.communicate(timeout=85)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                top.terminate()
                top.wait(timeout=10)
            (output/f'{case}.stdout.txt').write_text(stdout)
            if trace:
                try:
                    trace.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    trace.kill()
                    trace.wait()
                if trace.returncode != 0:
                    problems.append('B: Time Profiler did not finish; see stderr')
            if process.returncode != 0:
                problems.append(f'{case}: app probe exited {process.returncode}; see stderr')
                continue
        report = json.loads(stdout)
        (output/f'{case}.json').write_text(json.dumps(report, indent=2)+'\n')
        reports.append(report)
        for name, passed in report['gates'].items():
            if not passed:
                problems.append(f'{case}: {name} budget failed')
        if report['audioDevicesOpened'] is not False or not report['stopDisconnectsAndFreezes']:
            problems.append(f'{case}: fixture isolation/Stop failed')
        print(f"{case}: CPU {report['cpuCorePercent']:.4f}%, analysis {report['analysisCorePercent']:.4f}%, "
              f"draw {report['drawingCorePercent']:.4f}%, p95/max {report['p95FrameMs']}/{report['maxFrameMs']:.3f} ms", flush=True)
    baseline = next((r['cpuCorePercent'] for r in reports if r['case'] == 'E'), None)
    for report in reports:
        report['cpuDeltaFromE'] = None if baseline is None else report['cpuCorePercent']-baseline
    summary = {'measurements': reports, 'problems': problems,
               'scope': 'Production analyser/native renderer and production sink/owner with generated RAM input. '
                        'View payload includes actual IOSurface allocation and bounded raw rings, excludes framework/object overhead. '
                        'Actual device capture, WindowServer CPU, Allocations and visual review remain separate QA evidence.'}
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    if problems:
        raise SystemExit('\n'.join(problems))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.app, args.output)
