#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-only app capture proof with private native-messaging processes and RAM inputs."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted', 'Run only in a disposable hosted job; no local desktop/device test'
root = Path(__file__).resolve().parent.parent
profile = plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(a.app)],check=True,capture_output=True).stdout)
assert profile == plistlib.loads((root/'Cassini/Cassini.entitlements').read_bytes())
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
key = str(uuid.uuid4())
command = [str(a.app.resolve()/'Contents/MacOS/Cassini'), '--browser-capture-self-test', '--fixture-library-recording',
    '-CassiniCaptureID',key,'-CassiniDiskFree',str(20<<30),'-CassiniDiskTotal',str(100<<30),'-ApplePersistenceIgnoreState','YES']
process = subprocess.Popen(command,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
try:
    stdout, stderr = process.communicate(timeout=150)
except subprocess.TimeoutExpired:
    os.killpg(process.pid,signal.SIGTERM)
    try: stdout, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL); stdout, stderr = process.communicate()
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.with_suffix('.stderr.txt').write_text(stderr)
    raise AssertionError('Private app capture proof timed out; its own process group was stopped')
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.with_suffix('.stderr.txt').write_text(stderr)
assert process.returncode == 0, (process.returncode,stdout,stderr)
report = json.loads(stdout)
for name in ['twoProfilesSameTabIndependent','realSelectionUsesOwnedInputLifecycle','pageStopLeavesOtherMeetingRecording',
    'fallbackAndWorkerRecoveryKeepOneFolder','newCallAutoStartAndNotificationStop','deniedMicKeepsOthersRecording',
    'nothingStartedLeavesNoLibraryEntry','partialFailureRetriesOnlyThatMeeting','diskReserveStopsAndKeeps','nativeMessagingProcesses','exactProductProfile','nativeStopsBeforeBrowserFlush','nativeStartDoesNotReportFallback',
    'activeMoveRejectsRecording','recordingFollowsRelocatedBookmark','offlineLibraryIsNotRecreated']:
    assert report[name] is True, (name,report)
assert report['audioDevicesOpened'] is False and report['browserProfilesTouched'] is False
report['nativeArchitecture'] = os.uname().machine
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS signed app: independent native hosts/folders, per-side admission, same-folder fallback/recovery, auto Stop and permission failure policy')
