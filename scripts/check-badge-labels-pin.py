#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the W2.2 vectors and the reviewed catalog shared with the app."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FOLDER=ROOT/'Components/BadgeLabels/Contract'
COMMIT='5e0c34e0f1bb390298dabdf4eedc494e933fd329'

def verify():
    pin=json.loads((FOLDER/'UPSTREAM.json').read_text())
    assert pin['repository']=='codemyriad/cassini-ux' and pin['commit']==COMMIT
    catalog_pin=json.loads((ROOT/'Cassini/Resources/UX/UPSTREAM.json').read_text())
    assert pin['files']['strings.json']['commit']==catalog_pin['commit']
    assert (FOLDER/'strings.json').read_bytes()==(ROOT/'Cassini/Resources/UX/strings.json').read_bytes()
    for name,item in pin['files'].items():
        path=FOLDER/name
        assert path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(FOLDER.resolve()),name
        assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],name
    assert json.loads((FOLDER/'states-vectors.json').read_text())['version']==3
    assert json.loads((FOLDER/'format-vectors.json').read_text())['version']==5
    assert len(pin['files'])==26
    print('Standalone W2.2 snapshot: all26 hashes verified; reviewed catalog '+catalog_pin['commit'])

if __name__=='__main__':verify()
