#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the offline browser-opening page from the shared copy catalog and brand tokens."""
import argparse
import html
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def token_values(tokens_doc=None):
    if tokens_doc is None:
        tokens_doc = json.loads((ROOT/'Cassini/Resources/Brand/tokens.json').read_text())
    out = {}
    for name, spec in tokens_doc.get('tokens', {}).items():
        if spec.get('status') in ('decided', 'placeholder'):
            out[f'token.{name}.light'] = spec['light']
            out[f'token.{name}.dark'] = spec['dark']
    return out


def render(template, entries, tokens_doc=None):
    copy = {entry['id']: entry.get('mac') or entry['en'] for entry in entries}
    if '{{token.' in template:
        copy.update(token_values(tokens_doc))
    return re.sub(r'\{\{([\w.-]+)\}\}', lambda match: html.escape(copy[match[1]], quote=True), template)


def bundle(output):
    template = (ROOT/'Cassini/Resources/Cassini.html').read_text()
    entries = json.loads((ROOT/'Cassini/Resources/UX/strings.json').read_text())['entries']
    tokens_doc = json.loads((ROOT/'Cassini/Resources/Brand/tokens.json').read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(template, entries, tokens_doc))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    bundle(parser.parse_args().output)
