#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private native-messaging ownership proof; local runs require explicit headless opt-in."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import platform
import signal
import subprocess
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--headless', action='store_true', help='Exercise models and ownership without presenting app UI')
a = p.parse_args()
hosted = os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert hosted or (a.headless and os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1'), 'Local runs require --headless and explicit workflow opt-in'
headless = a.headless or (hosted and platform.machine() == 'x86_64')
root = Path(__file__).resolve().parent.parent
profile = plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(a.app)],check=True,capture_output=True).stdout)
assert profile == plistlib.loads((root/'Cassini/Cassini.entitlements').read_bytes())
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
key = str(uuid.uuid4())
command = [str(a.app.resolve()/'Contents/MacOS/Cassini'), '--browser-capture-self-test', '--fixture-library-recording',
    '-CassiniCaptureID',key,'-CassiniDiskFree',str(20<<30),'-CassiniDiskTotal',str(100<<30),'-ApplePersistenceIgnoreState','YES']
environment = dict(os.environ, CASSINI_HOSTED_SCREENSHOTS='1')
# Hosted Intel's Metal driver aborts on incidental SwiftUI presentation
# ("Target device architecture is nil"). Keep every ownership assertion, but
# drive navigation models without presenting windows or a menu-bar surface.
# ARM and dedicated UI/spectrogram jobs retain the real native views.
if headless:
    environment['CASSINI_SPECTRO'] = '0'
    command += ['--fixture-headless-ownership']
process = subprocess.Popen(command,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
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
if headless:
    assert report['disabledSpectrogramHasNoLayers'] is True, report
    assert report['headlessOwnershipNoVisibleWindows'] is True, report
for name in [
    'autoRecordUsesBrowserMicrophone','browserMeNeverAuthorizesHardware','firstRecordingDoesNotWaitForNotifications',
    'firstStartDeliveredWhileAcceptanceGated',
    'twoProfilesSameTabIndependent',
    'realSelectionUsesOwnedInputLifecycle',
    'pageStopLeavesOtherMeetingRecording',
    'fallbackAndWorkerRecoveryKeepOneFolder',
    'legacyAutomaticDeniedManualAllowed',
    'newCallAutoStartAndNotificationStop','endingAutomaticCaptureStopsOnce','separatedAdmissionNeedsNoHardwarePermission',
    'deniedMicKeepsOthersRecording',
    'failedNativeStartSkipsNotifications','nothingStartedLeavesNoLibraryEntry',
    'partialFailureRetriesOnlyThatMeeting',
    'diskReserveStopsAndKeeps',
    'nativeMessagingProcesses',
    'exactProductProfile',
    'browserMeOwnsBrowserFlush',
    'nativeStartDoesNotReportFallback',
    'activeMoveRejectsRecording',
    'recordingFollowsRelocatedBookmark',
    'shortcutNotifiesAfterOwnedSave',
    'offlineLibraryIsNotRecreated',
    'hangupStopsOnlyEndedMeeting',
    'unobservedFallbackExpires',
    'originalTransportRestoresSameFolder',
    'rapidReloadInvalidatesCachedSources','rapidReloadKeepsCaptureIdentity','stopAfterReloadedURLRoutesWithoutForcedFinalization',
    'reconnectedLostCallStopsNativeInputs',
    'returnCancelsPendingSystemPermission',
    'othersOffDoesNotStartSystem',
    'meOnlyLossBeforePCMRetainsProblem',
    'meOnlyPCMSurvivesControlRestart','browserMeFailureDoesNotOfferMicrophoneSettings',
    'closedTabStopsWithoutSystemFallback',
    'browserSelectionIgnoresHardwareFailure',
    'firstBrowserPacketMakesRecordingVisible',
    'ownedEditorUsesFolderIdentity',
    'ownedSilenceMatchesMenuAndPage',
    'micDCDoesNotMaskSilence',
    'ownedStopReturnsToLibraryBeforeFlush',
    'deniedMicIsNotSilent',
    'ownedDiskWarningUsesOverview',
    'deferredMovePreservesUnrelatedViewAndExport',
    'pendingSystemSourceIsNotPermissionFailure',
    'failedSystemSourceShowsPermissionGuidance',
    'companionSuggestionTracksConnection',
    'failedRetryDoesNotInheritStoppedSuccess',
]:
    assert report[name] is True, (name,report)
assert report['audioDevicesOpened'] is False and report['browserProfilesTouched'] is False
report['nativeArchitecture'] = os.uname().machine
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS signed app: independent native hosts/folders, per-side admission, same-folder fallback/recovery, auto Stop and permission failure policy')
