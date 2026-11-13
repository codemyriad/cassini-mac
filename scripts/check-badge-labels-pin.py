#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the merged badge/catalog snapshot and every vendored hash."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FOLDER=ROOT/'Components/BadgeLabels/Contract'
COMMIT='a08ee0aff82d58448b42d9799747088ae01ce1ea'

def verify():
    pin=json.loads((FOLDER/'UPSTREAM.json').read_text())
    assert pin['repository']=='codemyriad/cassini-ux' and pin['commit']==COMMIT
    for name,item in pin['files'].items():
        path=FOLDER/name
        assert path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(FOLDER.resolve()),name
        assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],name
    assert json.loads((FOLDER/'states-vectors.json').read_text())['version']==3
    assert json.loads((FOLDER/'format-vectors.json').read_text())['version']==5
    assert len(pin['files'])==26
    print('Badge catalog snapshot: all26 files match merged cassini-ux '+COMMIT)

if __name__=='__main__':verify()
