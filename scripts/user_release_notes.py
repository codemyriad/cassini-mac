#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""User-facing notes are curated fragments, never generated developer titles."""
from dataclasses import dataclass
import html
import re
import unicodedata

FALLBACK = 'Fixes and improvements under the hood. Nothing changes in how you use Cassini.'
GROUPS = {'new': 'New', 'better': 'Better', 'fixed': 'Fixed'}
LIMIT = 500
TECHNICAL = re.compile(r'#\d+|\bD\d+\b|\b(?:CI|PR|pull requests?|tests?|refactors?|tooling)\b|\b[\w-]+\.(?:swift|py|kt|json|ya?ml|sh|ts|js|md)\b', re.I)


def units(text):
    return len(text.encode('utf-16-le')) // 2


def validate(text):
    controls=any(unicodedata.category(c).startswith('C') and c not in '\n\t' for c in text)
    if not text.strip() or controls or TECHNICAL.search(text) or any(c in text for c in '`<>'):
        raise ValueError('User release notes must contain only plain user-facing text')
    if re.search(r'https?://|\[[^\]]*\]\(', text) or re.search(r'\bplease\b', text, re.I):
        raise ValueError('User release notes must not contain links or requests to please')


@dataclass(frozen=True)
class Fragment:
    name: str
    kind: str
    text: str


def parse_fragment(name, source):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*\.md', name):
        raise ValueError('Release fragment needs a short lowercase slug')
    header, separator, body = source.partition('\n---\n')
    if not separator or header not in [f'kind: {kind}' for kind in GROUPS]:
        raise ValueError('Release fragment needs kind: new, better or fixed and ---')
    text = ' '.join(body.split()).replace("'", '’')
    validate(text)
    if units(text) > 400:
        raise ValueError('Release fragment must be one or two short sentences (at most400 units)')
    return Fragment(name, header.removeprefix('kind: '), text)


def render(fragments):
    ordered = sorted(fragments, key=lambda f: (list(GROUPS).index(f.kind), f.name))
    def grouped(items):
        return '\n\n'.join(title+'\n'+'\n'.join('• '+f.text for f in items if f.kind == kind)
                           for kind, title in GROUPS.items() if any(f.kind == kind for f in items))
    if not ordered:
        return FALLBACK
    for fragment in ordered:
        validate(fragment.text)
    complete = grouped(ordered)
    if units(complete) <= LIMIT:
        return complete
    suffix = '\n\nand smaller fixes.'
    selected = []
    for fragment in ordered:
        if units(grouped(selected+[fragment])+suffix) <= LIMIT:
            selected.append(fragment)
    if not selected:
        raise ValueError('No user release fragment fits the release-note limit')
    return grouped(selected)+suffix


@dataclass(frozen=True)
class ReleaseNotes:
    user: str
    developer: str

    def __post_init__(self):
        validate(self.user)
        if units(self.user) > LIMIT:
            raise ValueError('User release notes exceed500 UTF-16 units')

    def github(self):
        lines = [('### '+line+'\n') if line in GROUPS.values() else
                 ('- '+line[2:]) if line.startswith('• ') else line for line in self.user.splitlines()]
        return '\n'.join(lines)+'\n\n<details>\n<summary>Developer changelog</summary>\n\n'+self.developer+'\n</details>\n'

    def html(self):
        lines = [('<h2>'+html.escape(line)+'</h2>') if line in GROUPS.values() else
                 '<p>'+html.escape(line.removeprefix('• '))+'</p>' for line in self.user.splitlines() if line]
        return '<!doctype html>\n<html lang="en"><meta charset="utf-8"><body>\n'+'\n'.join(lines)+'\n</body></html>\n'
