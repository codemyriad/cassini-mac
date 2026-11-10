#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-only production native-view A–E spectrogram measurements, no devices."""
import argparse
from contextlib import contextmanager
import ctypes
import select
import uuid
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


def probe_command(app: Path, case: str, output: Path, allocations: bool = False, profile: bool = False, motion: bool = False):
    executable = app.resolve()
    if executable.suffix == '.app':
        info = plistlib.loads((executable/'Contents/Info.plist').read_bytes())
        executable = executable/'Contents/MacOS'/info['CFBundleExecutable']
    command = [str(executable), '--spectrogram-self-test', '-SpectrogramCase', case,
               '-SpectrogramOutput', str(output.resolve()), '-ApplePersistenceIgnoreState', 'YES']
    if sum([allocations,profile,motion]) > 1:
        raise ValueError('Allocation, Time Profiler and motion diagnostics are separate processes')
    if allocations:
        command += ['-SpectrogramAllocations', '1']
    if profile:
        command += ['-SpectrogramProfileOnly', '1']
    if motion:
        command += ['-SpectrogramMotionOnly', '1']
    return command


def motion_driver_ready(line: str) -> bool:
    # The current driver's explicit post-setup, post-Settings/AX initialization
    # event. XCTest's "started" line still overlaps automation startup with B.
    return line.strip() == 'CASSINI_SPECTRO_MOTION_READY'


@contextmanager
def tracing_started():
    """Subscribe before spawning xctrace; its Darwin event means recording began."""
    notify = ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib')
    notify.notify_register_file_descriptor.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int),
                                                       ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    notify.notify_register_file_descriptor.restype = ctypes.c_uint32
    notify.notify_cancel.argtypes = [ctypes.c_int]
    name = 'io.codemyriad.cassini.profiler.' + uuid.uuid4().hex
    fd, token = ctypes.c_int(-1), ctypes.c_int()
    status = notify.notify_register_file_descriptor(name.encode(), ctypes.byref(fd), 0, ctypes.byref(token))
    if status != 0:
        raise RuntimeError(f'Cannot subscribe to recorder start: notify status {status}')
    try:
        def wait(timeout=90):
            ready, _, _ = select.select([fd.value], [], [], timeout)
            return bool(ready) and len(os.read(fd.value, 4)) == 4
        yield name, wait
    finally:
        # notify_cancel closes the descriptor allocated by libnotify.
        notify.notify_cancel(token.value)


def record_profile(app: Path, output: Path):
    """A second generated-input process: profile overhead never enters A–E."""
    process = trace = None
    stdout = ''
    proof = {'recordingStarted': False}
    with (output/'profile.stderr.txt').open('w') as stderr:
        try:
            with tracing_started() as (notification, wait_started):
                process = subprocess.Popen(probe_command(app, 'B', output, profile=True),
                    env=dict(os.environ,CASSINI_SPECTRO='1',CASSINI_SPECTRO_PROFILE_GATE='1'),
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
                trace = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                    '--attach', str(process.pid), '--output', str(output/'B-TimeProfiler.trace'),
                    '--notify-tracing-started', notification, '--no-prompt'], stdout=stderr, stderr=subprocess.STDOUT)
                # A cold recorder can outlive the entire generated-input interval.
                # Start the fixture clock only after Instruments confirms recording.
                if not wait_started():
                    raise TimeoutError('Time Profiler did not report recording started')
                stdout, _ = process.communicate(input='1', timeout=100)
                proof = dict(json.loads(stdout), recordingStarted=True)
        except (TimeoutError, subprocess.TimeoutExpired, ValueError, OSError, RuntimeError) as error:
            proof['error'] = str(error)
        finally:
            if process and process.poll() is None:
                process.kill(); process.wait()
            if trace:
                # Source completion/exit is the event. Finalize only afterwards.
                if trace.poll() is None: trace.send_signal(signal.SIGINT)
                try: trace.wait(timeout=20)
                except subprocess.TimeoutExpired: trace.kill(); trace.wait()
    (output/'profile.stdout.txt').write_text(stdout)
    proof['traceExitStatus'] = trace.returncode if trace else None
    proof['processExitStatus'] = process.returncode if process else None
    (output/'profile.json').write_text(json.dumps(proof, indent=2)+'\n')
    return (proof['processExitStatus'] == 0 and proof['traceExitStatus'] == 0 and
            proof.get('recordingStarted') is True and proof.get('diagnosticProfileOnly') is True and proof.get('audioDevicesOpened') is False and
            proof.get('analyzedFrames',0) > 0 and (output/'B-TimeProfiler.trace').is_dir())


def record_motion(app: Path, output: Path):
    """OS accessibility automation runs AFTER all uninstrumented A–E intervals.

    Even an initialized XCTest/Settings stack saturates a fresh hosted VM and
    leaves background work after it exits. It cannot share any timing run.
    """
    problems = []
    motion_ready = threading.Event()
    process = motion_driver = None
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
            if motion_driver_ready(line): ready.set()
            try:
                relay_motion_ack(line,current)
            except OSError as error:
                problems.append('motion acknowledgement relay failed: '+str(error))
    motion_relay = threading.Thread(target=relay_motion_events,daemon=True)
    motion_relay.start()
    try:
        if not motion_ready.wait(timeout=60):
            return False
        with (output/'motion.stderr.txt').open('w') as stderr:
            process = subprocess.Popen(probe_command(app,'B',output,motion=True),
                env=dict(os.environ,CASSINI_SPECTRO='1'),stdout=subprocess.PIPE,stderr=stderr,text=True)
            stdout,_ = process.communicate(timeout=100)
        (output/'motion.stdout.txt').write_text(stdout)
        report = json.loads(stdout)
        (output/'motion.json').write_text(json.dumps(report,indent=2)+'\n')
        return (process.returncode == 0 and report.get('diagnosticMotionOnly') is True and
                report.get('realMotionTransition') is True and report.get('audioDevicesOpened') is False and
                not problems)
    finally:
        if process and process.poll() is None: process.kill(); process.wait()
        if motion_driver:
            try: motion_driver.wait(timeout=20)
            except subprocess.TimeoutExpired: motion_driver.terminate(); motion_driver.wait(timeout=10)
        if motion_relay:
            motion_relay.join(timeout=5)
            if motion_relay.is_alive(): raise RuntimeError('Motion driver event stream did not close')
            motion_driver.stdout.close()
            motion_log.close()
        if motion_driver and motion_driver.returncode != 0:
            raise RuntimeError('Real System Settings motion driver failed; see motion-xctest.log')


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
        with (output/f'{case}.stderr.txt').open('w') as stderr, (output/f'{case}.top.txt').open('w') as top_log:
            process = top = None
            try:
                process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=stderr, text=True)
                (output/f'{case}.pid.txt').write_text(str(process.pid)+'\n')
                # Keep the busiest host processes: probe-only telemetry hid the
                # Spotlight/OS workload when a display interval exceeded100ms.
                top = subprocess.Popen(['/usr/bin/top', '-l', '90', '-s', '1', '-o', 'cpu', '-n', '20',
                                        '-stats', 'pid,command,cpu,mem'], stdout=top_log, stderr=subprocess.STDOUT)
                stdout, _ = process.communicate(timeout=200 if case == 'B' else 85)
            finally:
                if process and process.poll() is None:
                    process.kill()
                    process.wait()
                if top:
                    top.terminate(); top.wait(timeout=10)
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
        if case == 'B' and (not report['hideShowReleasesAndRestarts'] or report['liveCompositedInkPixels']['sound'] < 100 or report['liveCompositedInkPixels']['silence'] > 4):
            problems.append('B: hide/show lifecycle failed')
        print(f"{case}: CPU {report['cpuCorePercent']:.4f}%, analysis {report['analysisCorePercent']:.4f}%, "
              f"draw {report['drawingCorePercent']:.4f}%, CPU p95/max {report['p95FrameCPUMs']}/{report['maxFrameCPUMs']:.3f} ms; "
              f"wall diagnostic {report['p95FrameMs']}/{report['maxFrameMs']:.3f} ms", flush=True)
    try:
        if not record_motion(app, output):
            problems.append('actual System Settings motion transition failed in isolated diagnostic')
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        problems.append('Isolated motion diagnostic failed: '+str(error))
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
               'scope': 'Uninstrumented A–E production analyser/native renderer and sink/owner with generated RAM input. Motion/Settings, Time Profiler and Allocations each use separate diagnostic processes after every timing interval. '
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
