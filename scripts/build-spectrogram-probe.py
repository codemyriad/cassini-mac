#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Link an optimised native-view harness against the same app build's Release SDK objects.

Compile-only is safe locally; executing the result requires a disposable hosted Mac.
No app or SDK is rebuilt, and this standalone tool is never bundled with Cassini.
"""
import argparse
import platform
import plistlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('products', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
products = args.products.resolve()
objects = [products/(name+'.o') for name in ['CassiniSpectrogram','CassiniRecording','CassiniBrowserControl','CassiniLibrary','CassiniKit']]
for obj in objects:
    if not obj.is_file():
        raise SystemExit(f'Missing same-build Release SDK object: {obj}')
executable = args.output
if args.output.suffix == '.app':
    contents = args.output/'Contents'
    executable = contents/'MacOS'/args.output.stem
    executable.parent.mkdir(parents=True, exist_ok=True)
    (contents/'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'io.codemyriad.cassini.spectrogram-probe',
        'CFBundleExecutable':executable.name, 'CFBundleName':'Cassini spectrogram probe',
        'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0',
        'LSMinimumSystemVersion':'15.0', 'NSHighResolutionCapable':True,
    }))
else:
    executable.parent.mkdir(parents=True, exist_ok=True)
command = ['xcrun','swiftc','-O','-g','-parse-as-library','-swift-version','5','-D','DEBUG','-D','SPECTROGRAM_PROBE',
           '-target',platform.machine()+'-apple-macos15.0','-I',str(products),
           str(ROOT/'Cassini/Recording/RecordingSpectrogram.swift'),
           str(ROOT/'Spikes/Spectrogram/SampleClock.swift'),str(ROOT/'Spikes/Spectrogram/Budget.swift'),str(ROOT/'Spikes/Spectrogram/Events.swift'),str(ROOT/'Spikes/Spectrogram/Probe.swift'),str(ROOT/'Spikes/Spectrogram/main.swift'),
           *map(str,objects),'-o',str(executable)]
subprocess.run(command,check=True)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(args.output)],check=True)
subprocess.run(['codesign','--verify','--strict',str(args.output)],check=True)
print('Compiled optimised production native renderer with same-build Release SDK objects; no execution')
