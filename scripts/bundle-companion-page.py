#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the offline browser-opening page from the shared copy catalog, brand tokens, and Saturn mark."""
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


def mark_values():
    return {
        'mark.saturnNav': (ROOT/'Cassini/Resources/Brand/saturn-nav.svg').read_text().strip(),
    }


def render(template, entries, tokens_doc=None, raw_marks=None):
    copy = {entry['id']: entry.get('mac') or entry['en'] for entry in entries}
    if '{{token.' in template:
        copy.update(token_values(tokens_doc))
    marks = raw_marks if raw_marks is not None else (mark_values() if '{{mark.' in template else {})

    def _sub(match):
        key = match[1]
        if key in marks:
            return marks[key]
        return html.escape(copy[key], quote=True)

    return re.sub(r'\{\{([\w.-]+)\}\}', _sub, template)


def bundle(output):
    template = (ROOT/'Cassini/Resources/Cassini.html').read_text()
    entries = json.loads((ROOT/'Cassini/Resources/UX/strings.json').read_text())['entries']
    tokens_doc = json.loads((ROOT/'Cassini/Resources/Brand/tokens.json').read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(template, entries, tokens_doc, mark_values()))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    bundle(parser.parse_args().output)
