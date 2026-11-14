#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Locked-console fallback: render only Cassini's own frozen fixture views.

This is not a desktop/window screenshot or an XCTest interaction result.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path)
parser.add_argument('board',choices=['first-run','meeting','recording','received','export','search','settings-recording','settings-transcription','settings-library','settings-browser'])
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--listening',choices=['playing','finished'])
parser.add_argument('--speaker')
parser.add_argument('--speaker-editor',action='store_true',help='Render the read-only Name a speaker fixture')
parser.add_argument('--transcribing',action='store_true',help='Render the L-45 status instead of completed reading')
parser.add_argument('--scheme',choices=['light','dark'],default=os.environ.get('CASSINI_SCREENSHOT_SCHEME') or 'light')
parser.add_argument('--accent',default=os.environ.get('CASSINI_SCREENSHOT_ACCENT') or '')
args = parser.parse_args()
assert not args.listening or args.board == 'meeting', 'Listening preview requires the meeting fixture'
assert not args.speaker or args.listening, 'Speaker selection requires a listening preview'
assert not args.speaker_editor or args.board == 'meeting', 'Speaker editor requires the meeting fixture'
assert not args.transcribing or args.board == 'meeting', 'Transcribing preview requires the meeting fixture'
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit local workflow opt-in required'
app = args.app.resolve()
fixture = app/'Contents/Resources/Fixtures/Library'/('received-only' if args.board == 'received' else 'empty' if args.board == 'first-run' else 'main')
assert fixture.is_dir(),fixture
with tempfile.TemporaryDirectory(prefix='cassini-own-view-') as temporary:
    output,stderr = Path(temporary)/'stdout.json',Path(temporary)/'stderr.txt'
    render_id = str(uuid.uuid4())
    command = ['open','-W','-n','-a',str(app),'--stdout',str(output),'--stderr',str(stderr),
               '--env','CASSINI_LOCAL_WORKFLOW_TESTS=1','--env','CASSINI_HOSTED_SCREENSHOTS=1','--args',
               '-CassiniScreenshot',args.board,'-CassiniRenderID',render_id,'-CassiniFixture',str(fixture),'-CassiniNow','2026-10-27T13:18:00Z',
               '-ApplePersistenceIgnoreState','YES','-AppleLanguages','(en-GB)','-AppleLocale','en_GB',
               '-AppleInterfaceStyle','Dark' if args.scheme == 'dark' else 'Light']
    if args.accent: command += ['-AppleAccentColor',args.accent]
    if args.scheme == 'dark': command += ['-CassiniScreenshotScheme','dark']
    if args.speaker_editor: command += ['--speaker-editor-preview']
    if args.listening: command += ['-CassiniListeningPreview',args.listening]
    if args.speaker: command += ['-CassiniListeningSpeaker',args.speaker]
    if args.transcribing: command += ['-CassiniTranscribingPreview','YES']
    if args.board.startswith('settings-'): command += ['-CassiniSettingsID',str(uuid.uuid4())]
    try:
        # The fixture writes its report and exits. -W waits for that completion,
        # including a new instance (-n), before reading the final output once.
        # Keep the previous combined launch/report budget only as a hang guard.
        try:
            subprocess.run(command,check=True,capture_output=True,timeout=35)
        except (subprocess.TimeoutExpired,subprocess.CalledProcessError) as error:
            # TimeoutExpired retains bytes even when text mode is requested.
            launcher = (error.stderr or b'').decode('utf-8',errors='replace')
            fixture_diagnostics = stderr.read_text(errors='replace') if stderr.exists() else ''
            raise RuntimeError(f'Fixture launch failed ({error})\nopen stderr: {launcher}\nfixture stderr: {fixture_diagnostics}') from error
        try: body = json.loads(output.read_text())
        except (FileNotFoundError,json.JSONDecodeError) as error:
            raise RuntimeError('No fixture render: ' + (stderr.read_text() if stderr.exists() else 'no diagnostics')) from error
        assert body['board'] == args.board
        png = base64.b64decode(body['pngBase64'],validate=True)
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        if args.board.startswith('settings-'):
            assert int.from_bytes(png[16:20],'big') == 700 and 400 <= int.from_bytes(png[20:24],'big') <= 1050
        else: assert png[16:24] == bytes.fromhex('00000460000002d0')
        args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_bytes(png)
        print(args.board,int.from_bytes(png[16:20],'big'),int.from_bytes(png[20:24],'big'),'own-view render')
    finally:
        executable = app/'Contents/MacOS/Cassini'
        prefix = f'{executable} -CassiniScreenshot {args.board} -CassiniRenderID {render_id} '
        env = {key:value for key,value in os.environ.items() if key != 'COLUMNS'}
        rows = subprocess.check_output(['ps','-ww','-axo','pid=,command='],
            stdin=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env,text=True)
        for line in rows.splitlines():
            parts = line.strip().split(None,1)
            if len(parts) != 2: continue
            pid,command = parts
            if (command + ' ').startswith(prefix):
                try: os.kill(int(pid),signal.SIGTERM)
                except ProcessLookupError: pass
