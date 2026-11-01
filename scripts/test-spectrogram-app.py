#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-only production native-view A–E spectrogram measurements, no devices."""
import argparse
import json
import os
import plistlib
import threading
import signal
from pathlib import Path
import subprocess


def relay_motion_ack(line: str, request: Path) -> bool:
    """Forward only the current real-driver completion, never stale log output."""
    marker = 'CASSINI_SPECTRO_MOTION_ACK:'
    if marker not in line:
        return False
    try:
        response = json.loads(line.split(marker,1)[1])
        expected = json.loads(request.read_text())
        request_id = response['requestID']
        if not isinstance(request_id,str) or not request_id or request_id != expected['requestID']:
            return False
    except (ValueError,KeyError,TypeError,FileNotFoundError):
        return False
    ack = request.with_name('motion-ack.json')
    temporary = ack.with_name('.motion-ack.tmp')
    temporary.write_text(json.dumps({'requestID':request_id}))
    os.replace(temporary,ack)
    return True


def probe_command(app: Path, case: str, output: Path, allocations: bool = False, profile: bool = False):
    executable = app.resolve()
    if executable.suffix == '.app':
        info = plistlib.loads((executable/'Contents/Info.plist').read_bytes())
        executable = executable/'Contents/MacOS'/info['CFBundleExecutable']
    command = [str(executable), '--spectrogram-self-test', '-SpectrogramCase', case,
               '-SpectrogramOutput', str(output.resolve()), '-ApplePersistenceIgnoreState', 'YES']
    if allocations and profile:
        raise ValueError('Allocation and Time Profiler are separate processes')
    if allocations:
        command += ['-SpectrogramAllocations', '1']
    if profile:
        command += ['-SpectrogramProfileOnly', '1']
    return command


def motion_driver_started(line: str) -> bool:
    # This is XCTest's actual test-start event, seen in hosted logs. A suite
    # start or successful previous test cannot release the measurement.
    return (line.startswith("Test Case '-[CassiniWindowScreenshots.SpectrogramMotion ") and
            "testRealSystemSettingsMotionTransitions]' started." in line)


def record_profile(app: Path, output: Path):
    """A second generated-input process: profile overhead never enters A–E."""
    process = trace = None
    stdout = ''
    with (output/'profile.stderr.txt').open('w') as stderr:
        try:
            process = subprocess.Popen(probe_command(app, 'B', output, profile=True),
                                       env=dict(os.environ,CASSINI_SPECTRO='1'), stdout=subprocess.PIPE, stderr=stderr, text=True)
            trace = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                '--attach', str(process.pid), '--output', str(output/'B-TimeProfiler.trace')],
                stdout=stderr, stderr=subprocess.STDOUT)
            stdout, _ = process.communicate(timeout=100)
        finally:
            if process and process.poll() is None:
                process.kill(); process.wait()
            if trace:
                # Source completion/exit is the event. Finalize only afterwards.
                if trace.poll() is None: trace.send_signal(signal.SIGINT)
                try: trace.wait(timeout=20)
                except subprocess.TimeoutExpired: trace.kill(); trace.wait()
    (output/'profile.stdout.txt').write_text(stdout)
    proof = json.loads(stdout)
    proof['traceExitStatus'] = trace.returncode
    proof['processExitStatus'] = process.returncode
    (output/'profile.json').write_text(json.dumps(proof, indent=2)+'\n')
    return (process.returncode == 0 and trace.returncode == 0 and
            proof.get('diagnosticProfileOnly') is True and proof.get('audioDevicesOpened') is False and
            proof.get('analyzedFrames',0) > 0 and (output/'B-TimeProfiler.trace').is_dir())


def measure(app: Path, output: Path):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise SystemExit('This view/display-link probe requires a disposable GitHub-hosted Mac')
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    problems = []
    for case in 'ABCDE':
        subprocess.run(['defaults', 'write', 'com.apple.universalaccess', 'reduceMotion', '-bool', 'false'], check=True)
        env = dict(os.environ, CASSINI_SPECTRO='0' if case == 'E' else '1')
        command = probe_command(app, case, output)
        motion_driver = None
        motion_ready = threading.Event()
        motion_log = None
        motion_relay = None
        if case == 'B':
            request = output.resolve()/'motion-request.json'
            request.unlink(missing_ok=True)
            spec, = Path('build/Build/Products').glob('*.xctestrun')
            motion_env = dict(os.environ, TEST_RUNNER_CASSINI_SPECTRO_MOTION_GATE='1',
                              TEST_RUNNER_CASSINI_SPECTRO_MOTION_REQUEST=str(request))
            motion_log = (output/'motion-xctest.log').open('w')
            motion_driver = subprocess.Popen(['xcodebuild', 'test-without-building', '-xctestrun', str(spec),
                '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
                '-only-testing:CassiniWindowScreenshots/SpectrogramMotion',
                '-resultBundlePath', str(output/'Motion.xcresult')],
                env=motion_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            def relay_motion_events(driver=motion_driver,log=motion_log,current=request,ready=motion_ready):
                for line in driver.stdout:
                    log.write(line);log.flush()
                    if motion_driver_started(line): ready.set()
                    try:
                        relay_motion_ack(line,current)
                    except OSError as error:
                        problems.append('B: motion acknowledgement relay failed: '+str(error))
            motion_relay = threading.Thread(target=relay_motion_events,daemon=True)
            motion_relay.start()
        with (output/f'{case}.stderr.txt').open('w') as stderr, (output/f'{case}.top.txt').open('w') as top_log:
            process = top = None
            try:
                if motion_driver and not motion_ready.wait(timeout=60):
                    problems.append('B: motion test never entered execution; see motion-xctest.log')
                    continue
                process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=stderr, text=True)
                top = subprocess.Popen(['/usr/bin/top', '-l', '90', '-s', '1', '-pid', str(process.pid),
                                        '-stats', 'pid,cpu'], stdout=top_log, stderr=subprocess.STDOUT)
                stdout, _ = process.communicate(timeout=200 if case == 'B' else 85)
            finally:
                if process and process.poll() is None:
                    process.kill()
                    process.wait()
                if top:
                    top.terminate(); top.wait(timeout=10)
                if motion_driver:
                    try:
                        motion_driver.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        motion_driver.terminate()
                        motion_driver.wait(timeout=10)
                    motion_relay.join(timeout=5)
                    if motion_relay.is_alive():
                        problems.append('B: motion event stream did not close after its driver exited')
                    else:
                        motion_log.close()
                    if motion_driver.returncode != 0:
                        problems.append('B: actual System Settings motion transition failed; see motion-xctest.log')
            (output/f'{case}.stdout.txt').write_text(stdout)
            if process.returncode != 0:
                try:
                    partial = json.loads(stdout)
                    (output/f'{case}.json').write_text(json.dumps(partial, indent=2)+'\n')
                except (ValueError, TypeError):
                    pass
                problems.append(f'{case}: app probe exited {process.returncode}; see stderr')
                continue
        report = json.loads(stdout)
        (output/f'{case}.json').write_text(json.dumps(report, indent=2)+'\n')
        reports.append(report)
        if report['reducedMotion']:
            problems.append(f'{case}: system remained in Reduced Motion during normal-motion pacing measurement')
        for name, passed in report['gates'].items():
            if not passed:
                problems.append(f'{case}: {name} budget failed')
        if report['audioDevicesOpened'] is not False or not report['stopDisconnectsAndFreezes'] or not report['detachReleasesSurfaces']:
            problems.append(f'{case}: fixture isolation/Stop failed')
        if case == 'B' and (not report['hideShowReleasesAndRestarts'] or not report['realMotionTransition'] or report['liveCompositedInkPixels']['sound'] < 100 or report['liveCompositedInkPixels']['silence'] > 4):
            problems.append('B: hide/show lifecycle failed')
        print(f"{case}: CPU {report['cpuCorePercent']:.4f}%, analysis {report['analysisCorePercent']:.4f}%, "
              f"draw {report['drawingCorePercent']:.4f}%, p95/max {report['p95FrameMs']}/{report['maxFrameMs']:.3f} ms", flush=True)
    # Backtraces contain symbols and sizes only, never heap contents or a raw
    # memory graph (which could include inherited runner credentials).
    allocation = subprocess.run(probe_command(app, 'B', output, allocations=True),
        env=dict(os.environ, CASSINI_SPECTRO='1', MallocStackLogging='1'),
        capture_output=True, text=True, timeout=120)
    (output/'allocations.stderr.txt').write_text(allocation.stderr)
    (output/'allocations.stdout.txt').write_text(allocation.stdout)
    if allocation.returncode:
        problems.append('Separate live-allocation proof failed; see allocations.stderr.txt')
    else:
        proof = json.loads(allocation.stdout)
        assert proof['allocationStacksCollected'] and proof['detachReleasesSurfaces'] and proof['audioDevicesOpened'] is False
        (output/'allocations.json').write_text(json.dumps(proof, indent=2)+'\n')
    try:
        if not record_profile(app, output):
            problems.append('Separate Time Profiler proof failed; see profile.json/profile.stderr.txt')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        problems.append('Separate Time Profiler proof failed: '+str(error))
    baseline = next((r['cpuCorePercent'] for r in reports if r['case'] == 'E'), None)
    for report in reports:
        report['cpuDeltaFromE'] = None if baseline is None else report['cpuCorePercent']-baseline
    summary = {'measurements': reports, 'problems': problems,
               'scope': 'Uninstrumented A–E production analyser/native renderer and sink/owner with generated RAM input. Time Profiler and Allocations each use a separate process. '
                        'View payload includes actual IOSurface allocation and bounded raw rings, excludes framework/object overhead. '
                        'Actual device capture, WindowServer CPU, Allocations and visual review remain separate QA evidence.'}
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    if problems:
        raise SystemExit('\n'.join(problems))


def run(app: Path, output: Path):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise SystemExit('Requires a disposable GitHub-hosted Mac; no local desktop test')
    # Hosted images enable Reduce Motion. Measure continuous display-link pacing
    # using the real system preference, never an injected renderer override.
    setting = ['com.apple.universalaccess', 'reduceMotion']
    old = subprocess.run(['defaults', 'read', *setting], capture_output=True, text=True)
    try:
        subprocess.run(['defaults', 'write', *setting, '-bool', 'false'], check=True)
        measure(app, output)
    finally:
        command = ['defaults', 'write', *setting, '-bool', 'true' if old.stdout.strip() == '1' else 'false'] if old.returncode == 0 else ['defaults', 'delete', *setting]
        subprocess.run(command, check=False, capture_output=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.app, args.output)
