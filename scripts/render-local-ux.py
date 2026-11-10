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
parser.add_argument('board',choices=['meeting','recording','received','export','search','settings-recording','settings-transcription'])
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--listening',choices=['playing','finished'])
parser.add_argument('--speaker')
args = parser.parse_args()
assert not args.listening or args.board == 'meeting', 'Listening preview requires the meeting fixture'
assert not args.speaker or args.listening, 'Speaker selection requires a listening preview'
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit local workflow opt-in required'
app = args.app.resolve()
fixture = app/'Contents/Resources/Fixtures/Library'/('received-only' if args.board == 'received' else 'main')
assert fixture.is_dir(),fixture
with tempfile.TemporaryDirectory(prefix='cassini-own-view-') as temporary:
    output,stderr = Path(temporary)/'stdout.json',Path(temporary)/'stderr.txt'
    command = ['open','-W','-n','-a',str(app),'--stdout',str(output),'--stderr',str(stderr),
               '--env','CASSINI_LOCAL_WORKFLOW_TESTS=1','--env','CASSINI_HOSTED_SCREENSHOTS=1','--args',
               '-CassiniScreenshot',args.board,'-CassiniFixture',str(fixture),'-CassiniNow','2026-10-27T13:18:00Z',
               '-ApplePersistenceIgnoreState','YES','-AppleLanguages','(en-GB)','-AppleLocale','en_GB',
               '-AppleInterfaceStyle','Light','-AppleAccentColor','4']
    if args.listening: command += ['-CassiniListeningPreview',args.listening]
    if args.speaker: command += ['-CassiniListeningSpeaker',args.speaker]
    if args.board.startswith('settings-'): command += ['-CassiniSettingsID',str(uuid.uuid4())]
    try:
        # The fixture writes its report and exits. -W waits for that completion,
        # including a new instance (-n), before reading the final output once.
        # Keep the previous combined launch/report budget only as a hang guard.
        subprocess.run(command,check=True,capture_output=True,timeout=35)
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
        prefix = str(app/'Contents/MacOS/Cassini') + ' -CassiniScreenshot ' + args.board + ' '
        for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
            pid,command = line.strip().split(None,1)
            if command.startswith(prefix):
                try: os.kill(int(pid),signal.SIGTERM)
                except ProcessLookupError: pass
