#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile actual W2.2/W2.1 + localization helpers, offscreen, under heavy-run."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',required=True,type=Path)
parser.add_argument('--baseline-ref',default='aa634170abd194781f2c9c9c1658798d26aa5e1c')
args=parser.parse_args();output=args.output.expanduser().resolve()
if output==root or root in output.parents:parser.error('Use output outside checkout')
subprocess.run([sys.executable,str(root/'scripts/check-badge-labels-pin.py')],check=True)
output.mkdir(parents=True,exist_ok=True);inputs=output/'inputs';inputs.mkdir(exist_ok=True)
baseline=subprocess.check_output(['git','rev-parse',args.baseline_ref+'^{commit}'],cwd=root,text=True).strip()
before=subprocess.check_output(['git','show',baseline+':Sources/CassiniLibrary/Localization/strings.json'],cwd=root)
(inputs/'before-strings.json').write_bytes(before)
files=['Cassini/Theme/CassiniTokens.swift','Components/StatusBadge/MeetingStatusBadge.swift',
       'Sources/CassiniLibrary/LibraryLocalization.swift','Sources/CassiniLibrary/LibraryFormat.swift',
       'Components/BadgeLabels/BadgeLabelPresenter.swift','Components/BadgeLabels/CatalogStatusBadge.swift',
       'Spikes/BadgeLabels/LocalizationBundleFixture.swift','Spikes/BadgeLabels/Proof.swift']
architecture=platform.machine()
if architecture not in ('arm64','x86_64'):parser.error('Native Mac required')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
binary=output/'badge-label-proof'
subprocess.run(['xcrun','swiftc','-parse-as-library','-sdk',sdk,'-target',architecture+'-apple-macosx15.0',
                *[str(root/f) for f in files],'-o',str(binary)],cwd=root,check=True)
subprocess.run([str(binary),str(output),str(root/'Components/BadgeLabels/Contract')],cwd=root,check=True,timeout=60)
receipt=dict(architecture=architecture,baselineCommit=baseline,baselineCatalogSHA256=hashlib.sha256(before).hexdigest(),
             upstream=json.loads((root/'Components/BadgeLabels/Contract/UPSTREAM.json').read_text()),
             sourceSHA256={f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},
             producerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             checks=json.loads((output/'checks.json').read_text()))
(output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
