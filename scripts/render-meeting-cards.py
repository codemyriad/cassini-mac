#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile actual new/baseline SwiftUI views; no app launch, devices or signing.

Run under ~/bin/heavy-run. Tokens come from #270, unmodified, in a temporary
output folder. After #270 merges, --tokens-ref origin/main is sufficient.
"""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--tokens-ref', required=True, help='Commit/ref containing CassiniTokens.swift from #270')
parser.add_argument('--baseline-ref', default='origin/main')
args = parser.parse_args()
output = args.output.expanduser().resolve()
if output == root or root in output.parents:
    parser.error('Use an output directory outside the checkout')
output.mkdir(parents=True, exist_ok=True)
inputs = output / 'inputs'
inputs.mkdir(exist_ok=True)
def git(*args):
    return subprocess.check_output(['git', *args], cwd=root, text=True)
def extract(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
token_ref = git('rev-parse', args.tokens_ref + '^{commit}').strip()
baseline_ref = git('rev-parse', args.baseline_ref + '^{commit}').strip()
tokens = git('show', token_ref + ':Cassini/Theme/CassiniTokens.swift')
baseline = git('show', baseline_ref + ':Cassini/Library/LibraryView.swift')
theme = extract(baseline, 'enum LibraryTheme {')
row = extract(baseline, 'private func row(_ meeting: LibraryMeeting)')
pill = extract(baseline, 'private func badgePill(')
start = baseline.index('.listRowBackground(') + len('.listRowBackground(')
depth = 1; end = start
while depth:
    depth += (baseline[end] == '(') - (baseline[end] == ')')
    end += 1
background = baseline[start:end-1].replace('store.selectedKeys.contains(meeting.libraryKey)', 'selected')
fixture = (root / 'Spikes/MeetingCard/LegacyFixture.swift').read_text()
legacy = fixture + '\n' + theme + '\nprivate extension LegacyCard {\n' + row + '\n' + pill + '\n' + 'var background:some View { ' + background + ' }\n}\n'
(inputs / 'CassiniTokens.swift').write_text(tokens)
(inputs / 'LegacyCard.swift').write_text(legacy)
component = root / 'Components/MeetingCard/MeetingCard.swift'
proof = root / 'Spikes/MeetingCard/Proof.swift'
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
binary = output / 'meeting-card-proof'
architecture = platform.machine()
if architecture not in ('arm64', 'x86_64'):
    parser.error('Native proof supports Apple Silicon and Intel Macs')
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-sdk', sdk, '-target', architecture + '-apple-macosx15.0',
                str(inputs / 'CassiniTokens.swift'), str(inputs / 'LegacyCard.swift'), str(component), str(proof),
                '-o', str(binary)], cwd=root, check=True)
subprocess.run([str(binary), str(output)], cwd=root, check=True, timeout=60)
receipt = {'architecture': architecture, 'proofSHA256': hashlib.sha256(proof.read_bytes()).hexdigest(),
           'rendererSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'tokensCommit': token_ref, 'tokensSHA256': hashlib.sha256(tokens.encode()).hexdigest(),
           'baselineCommit': baseline_ref, 'baselineSourceSHA256': hashlib.sha256(baseline.encode()).hexdigest(),
           'legacyFixtureSHA256': hashlib.sha256(fixture.encode()).hexdigest(),
           'legacyRendererSHA256': hashlib.sha256(legacy.encode()).hexdigest(),
           'componentSHA256': hashlib.sha256(component.read_bytes()).hexdigest(),
           'checks': json.loads((output / 'checks.json').read_text())}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
