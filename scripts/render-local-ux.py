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
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app',type=Path)
parser.add_argument('board',choices=['recording','received','export','search'])
parser.add_argument('--output',type=Path,required=True)
args = parser.parse_args()
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1', 'Explicit local workflow opt-in required'
app = args.app.resolve()
fixture = app/'Contents/Resources/Fixtures/Library'/('received-only' if args.board == 'received' else 'main')
assert fixture.is_dir(),fixture
with tempfile.TemporaryDirectory(prefix='cassini-own-view-') as temporary:
    output,stderr = Path(temporary)/'stdout.json',Path(temporary)/'stderr.txt'
    command = ['open','-n','-a',str(app),'--stdout',str(output),'--stderr',str(stderr),
               '--env','CASSINI_LOCAL_WORKFLOW_TESTS=1','--env','CASSINI_HOSTED_SCREENSHOTS=1','--args',
               '-CassiniScreenshot',args.board,'-CassiniFixture',str(fixture),'-CassiniNow','2026-10-27T13:18:00Z',
               '-ApplePersistenceIgnoreState','YES','-AppleLanguages','(en-GB)','-AppleLocale','en_GB',
               '-AppleInterfaceStyle','Light','-AppleAccentColor','4']
    try:
        subprocess.run(command,check=True,capture_output=True,timeout=10)
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                body = json.loads(output.read_text())
                assert body['board'] == args.board
                png = base64.b64decode(body['pngBase64'],validate=True)
                assert png[:8] == b'\x89PNG\r\n\x1a\n' and png[16:24] == bytes.fromhex('00000460000002d0')
                args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_bytes(png)
                print(args.board,'1120x720 own-view render'); break
            except (FileNotFoundError,json.JSONDecodeError): time.sleep(.2)
        else: raise RuntimeError('No fixture render: ' + (stderr.read_text() if stderr.exists() else 'no diagnostics'))
    finally:
        prefix = str(app/'Contents/MacOS/Cassini') + ' -CassiniScreenshot ' + args.board + ' '
        for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
            pid,command = line.strip().split(None,1)
            if command.startswith(prefix):
                try: os.kill(int(pid),signal.SIGTERM)
                except ProcessLookupError: pass
