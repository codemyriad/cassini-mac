#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the W2.2 snapshot hashes and vector copy against its reviewed catalog."""
import hashlib
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FOLDER=ROOT/'Components/BadgeLabels/Contract'
COMMIT='dd06a62dc881034fed417b000f47004e577a3fb0'

def verify_vector_copy():
    entries={entry['id']:entry for entry in json.loads((FOLDER/'strings.json').read_text())['entries']}
    states=json.loads((FOLDER/'states-vectors.json').read_text())
    formats=json.loads((FOLDER/'format-vectors.json').read_text())
    clocks={vector['ms']:vector['out'] for vector in formats['liveBadge']}

    def badge_text(kind,fields):
        key='states.badge.'+kind
        args={}
        if kind=='recording':
            args['liveBadge']=clocks[fields['liveMs']]
        if kind=='transcribing':
            minutes=fields.get('etaMinutes')
            if minutes is None or minutes<0:key+='.noEta'
            elif minutes==0:key+='.underMinute'
            else:args['n']=minutes
        entry=entries[key]
        text=entry['plural']['one' if args['n']==1 else 'other'] if 'n' in args else entry['en']
        return text.format(**args)

    for vector in states['vectors']+states['entryVectors']:
        badge=vector['badge']
        if badge is not None:
            assert badge['text']==badge_text(badge['kind'],vector['fields']),vector['id']
    for vector in formats['eta']:
        assert vector['out']==badge_text('transcribing',{'etaMinutes':vector['minutes']}),vector
    # Date/time/duration formatting is tested by the native proof and Library tests.
    # Here the placeholders may vary, but all literal catalog copy must match.
    for vector in formats['previewSubtitle']:
        if vector['received']:
            template=entries['format.previewSubtitle.received']['en']
            pattern=''.join('.+?' if part in ('{day}','{time}','{duration}') else re.escape(part)
                            for part in re.split(r'(\{\w+\})',template))
            assert re.fullmatch(pattern,vector['out']),vector

def verify():
    pin=json.loads((FOLDER/'UPSTREAM.json').read_text())
    assert pin['repository']=='codemyriad/cassini-ux' and pin['commit']==COMMIT
    # This standalone snapshot retains its reviewed catalog and vectors when the
    # live app advances (D104). check-ux-copy.py validates the app's separate pin.
    for name,item in pin['files'].items():
        path=FOLDER/name
        assert path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(FOLDER.resolve()),name
        assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],name
    assert json.loads((FOLDER/'states-vectors.json').read_text())['version']==3
    assert json.loads((FOLDER/'format-vectors.json').read_text())['version']==5
    assert len(pin['files'])==26
    verify_vector_copy()
    print('Standalone W2.2 snapshot: all26 hashes verified; reviewed catalog '+pin['commit'])

if __name__=='__main__':verify()
