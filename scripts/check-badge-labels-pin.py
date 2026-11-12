#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the standalone W2.2 snapshot; no live app pin or bundle changes."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FOLDER=ROOT/'Components/BadgeLabels/Contract'
COMMIT='793209cb3425bece7143178458fddd94b691e12d'

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
    print('Standalone W2.2 snapshot: all26 files match merged W0.4 '+COMMIT)

if __name__=='__main__':verify()
