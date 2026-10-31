#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the offline browser-opening page from the shared copy catalog."""
import argparse
import html
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def render(template, entries):
    copy = {entry['id']: entry.get('mac') or entry['en'] for entry in entries}
    return re.sub(r'\{\{([\w.]+)\}\}', lambda match: html.escape(copy[match[1]], quote=True), template)


def bundle(output):
    template = (ROOT/'Cassini/Resources/Cassini.html').read_text()
    entries = json.loads((ROOT/'Cassini/Resources/UX/strings.json').read_text())['entries']
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(template, entries))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    bundle(parser.parse_args().output)
