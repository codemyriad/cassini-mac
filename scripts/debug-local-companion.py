#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted diagnostic: recompile only the UI harness over verified private products."""
import os
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PRODUCER = ROOT/'producer'
SOURCE_SHA = '13ec9ec8951c62f20be319870aaa886d41b95320'
assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
metadata = json.loads((ROOT/'build/producer-artifacts/debug.json').read_text())
producer_sha = subprocess.check_output(['git','-C',PRODUCER,'rev-parse','HEAD'],text=True).strip()
assert producer_sha == metadata['commit'], 'Producer checkout must match the actual PR merge product'
# Test edits may differ; every product source and pin must still match.
product_paths = ['Cassini','BrowserSetup','Sources','QuickLook',
    'Whistle','Opus','Parakeet','ModelDownloads','BrowserExtension','browser-protocol','Package.swift','Package.resolved',
    'project.yml','Cassini.xcodeproj']
for checkout in [ROOT,PRODUCER]:
    subprocess.run(['git','diff','--exit-code',SOURCE_SHA,'HEAD','--',*product_paths],cwd=checkout,check=True)
subprocess.run([sys.executable,PRODUCER/'scripts/ci-products.py','unpack','debug',ROOT/'build/producer-artifacts'],check=True)
products = ROOT/'build/Build/Products'
assert not products.exists(), 'Never overwrite producer products'
products.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['ditto',PRODUCER/'build/Build/Products',products],check=True)
app = products/'Debug/Cassini.app'
original = PRODUCER/'build/Build/Products/Debug/Cassini.app'
subprocess.run(['codesign','--verify','--deep','--strict',original],check=True)
runner, = (products/'Debug').glob('*-Runner.app')
bundle, = runner.rglob('CassiniWindowScreenshots.xctest')
name = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
developer = Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
platform = developer/'Platforms/MacOSX.platform/Developer'
entitlements = ROOT/'build/guide-runner-entitlements.plist'
entitlements.write_bytes(subprocess.run(['codesign','-d','--entitlements',':-',runner],check=True,capture_output=True).stdout)
subprocess.run(['xcrun','swiftc','-emit-library','-module-name','CassiniWindowScreenshots','-swift-version','5',
    '-target','arm64-apple-macos15.0','-I',platform/'usr/lib','-L',platform/'usr/lib','-F',platform/'Library/Frameworks',
    '-Xlinker','-rpath','-Xlinker',platform/'usr/lib',
    '-Xlinker','-rpath','-Xlinker',platform/'Library/Frameworks',
    ROOT/'UITests/LocalCompanionInstall.swift','-o',bundle/'Contents/MacOS'/name],check=True)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',bundle],check=True)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--entitlements',entitlements,runner],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',runner],check=True)
subprocess.run([sys.executable,ROOT/'scripts/test-local-companion.py',app,'--output',ROOT/'build/local-companion'],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',original],check=True)
