#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the real app's meeting-page turn preparation proof (#118) over its bundled fixture."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path)
parser.add_argument('--output',type=Path,required=True)
args = parser.parse_args()
hosted = os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit workflow opt-in required'
app = args.app.resolve()
result = subprocess.run([str(app/'Contents/MacOS/Cassini'),'--meeting-preparation-self-test','-CassiniScreenshot','library',
                         '-CassiniFixture',str(app/'Contents/Resources/Fixtures/Library/main'),
                         '-CassiniNow','2026-10-27T13:18:00Z','-ApplePersistenceIgnoreState','YES'],
                        env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=45)
args.output.parent.mkdir(parents=True,exist_ok=True)
stderr = result.stderr
if os.environ.get('CASSINI_TRANSCRIPT_RENDER'):
    for line in stderr.splitlines():
        if line.startswith('CASSINI_TRANSCRIPT_PNG:'):
            Path(os.environ['CASSINI_TRANSCRIPT_RENDER']).write_bytes(base64.b64decode(line.split(':',1)[1],validate=True))
    stderr = '\n'.join(line for line in stderr.splitlines() if not line.startswith('CASSINI_TRANSCRIPT_PNG:'))
args.output.with_suffix('.stderr.txt').write_text(stderr)
assert result.returncode == 0,(result.returncode,result.stdout,stderr)
report = json.loads(result.stdout)
assert all(report[name] is True for name in ('preparedOffMain','mainActorProgressed','outageCancelled','recoveryDelivered','readoutDeliveredWithTurns',
    'nativeTrackMatchesThumbTravel','nativePointerClampsToTrack','nativePointerPreservesThumbGrabOffset','nativePointerSnapAndDragReadout','nativeDragReadoutClears',
    'nativeMouseDownSnapsNearTurn','nativeDisabledPointerIsIgnored',
    'nativeMouseDownPreservesOffCenterGrab','nativeStationaryThumbDoesNotSnap','nativeVerticalThumbMovementDoesNotSeek','nativeZeroWidthThumbDoesNotSeek','nativeThumbGrabPreservesExactValues','nativePointerKeepsTranscriptFocus','nativeMouseUpDoesNotRepeatSeek',
    'nativeMouseDragUsesWindowCoordinates','nativeMouseDownClampsBothEnds','nativeMouseDragStopsWhenDisabled','nativeMouseDragStopsWhenDetached',
    'nativeAccessibilitySeekDoesNotSnap','nativeAccessibilityTenSecondStep','nativeStopClearsSnap',
    'mergeWhilePreparedResolvesReadoutAndHeaders','mergeWhilePreparedResolvesBar','mergedSpeakerRowStopsCachedListening',
    'suspendedMergeResolvesReadoutAndHeaders','unlistedSpeechIsNotSilence','mergedPreparationRecovers',
    'asideHasExactListeningTint','asideNativeListenButton','asideButtonAccessibility','asideButtonGeometry','unchangedRowDoesNotRestyle',
    'clockKeepsSelectionAndInlineButton','bodyUsesEightPercentAndClearsAside','focusedTranscriptShiftReturnPlays',
    'asideActionSelectsOwnRunAndHost','explicitReplayResumesTranscriptFollow',
    'inlineButtonFocusableWithoutFullKeyboardAccess','tabSkipsSelectableTranscript',
    'pointerFocusedTranscriptTabAdvances','pointerFocusedTranscriptBacktabAdvances',
    'inlineFocusInvalidatesRing','inlineBlurInvalidatesRing','inlineReturnSpaceKeypadActivate',
    'inlineShiftReturnKeypadPlayAndKeepFocus','disabledInlineButtonCannotFocusOrActivate','focusedInlineSpacePrecedesPlayer',

    'inlineButtonSpaceInvokesListen','disabledInlineButtonDoesNotConsumeSpace','inlineButtonShiftReturnPlaysHost',
    'focusedButtonPrecedesBarePlayback','disabledButtonNotPressedByMediaRouter',
    'titleAlignmentMacOS15KeepsInset44','titleAlignmentMacOS27AlignsFrom206To280','titleAlignmentAncestorShiftRealigns',
    'titleAlignmentWideLeadingControlsClampToZero','titleAlignmentPassThroughHitTesting','titleAlignmentRejectsStaleAndInvalidProposals',
    'speakerRowReadOnlyKeepsPrimaryInk','speakerRowCaptionUsesFullRowWidth',
    'brandTokensSynced','brandTokensRejectsDrift',
    'sessionPreparedOffMain','sessionMainActorProgressed','sessionSwitchCancelled',
    'sessionCachedSwitchSkipsPreparation','sessionSpeakerSlotsMatchFirstSpeech')),report
assert report['audioDevicesOpened'] is False
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS production meeting preparation/readout, native scrubber snapping, drag readout and VoiceOver seeks')
