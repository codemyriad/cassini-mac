#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offscreen L-46 native component proof. Run under ~/bin/heavy-run."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
output = args.output.expanduser().resolve()
if output == root or root in output.parents:
    parser.error('Keep output outside checkout')
output.mkdir(parents=True, exist_ok=True)
baseline = '2c21d2c4d78a963500cae2f1a3e638005b26c134'
component = Path('Components/StatusBadge/MeetingStatusBadge.swift')
previous = subprocess.check_output(['git', 'show', baseline + ':' + str(component)], cwd=root, text=True)
renamed = previous.replace('StatusBadgeKind', 'PreviousStatusBadgeKind').replace('MeetingStatusBadge', 'PreviousMeetingStatusBadge')
(output / 'Previous.swift').write_text(renamed)
sources = [root / 'Cassini/Theme/CassiniTokens.swift', root / 'Components/MeetingCard/MeetingCard.swift',
           root / component, root / 'Spikes/StatusBadgeNeutralWash/Proof.swift']
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
arch = platform.machine()
if arch not in ('arm64', 'x86_64'):
    parser.error('Native Mac required')
binary = output / 'badge-wash-proof'
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-sdk', sdk, '-target', arch + '-apple-macosx15.0',
                *map(str, sources), str(output / 'Previous.swift'), '-o', str(binary)], cwd=root, check=True)
subprocess.run([str(binary), str(output)], cwd=root, check=True, timeout=60)
receipt = {'baselineCommit': baseline, 'baselineSHA256': hashlib.sha256(previous.encode()).hexdigest(),
           'architecture': arch, 'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
           'rendererSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
           'caseCount': len(json.loads((output / 'checks.json').read_text())),
           'checksSHA256': hashlib.sha256((output / 'checks.json').read_bytes()).hexdigest()}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
