#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile only the experimental spectrogram SDK, retaining verified other objects."""
from pathlib import Path
import platform
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
baseline = Path(sys.argv[1]).resolve()
output = root/'build/lab-products'
output.mkdir(parents=True,exist_ok=True)
for item in baseline.iterdir():
    if not item.name.startswith('CassiniSpectrogram'):
        link=output/item.name
        if link.is_symlink():
            if link.resolve() != item.resolve(): raise SystemExit('Mismatched original product: '+str(link))
        elif link.exists(): raise SystemExit('Unexpected existing product: '+str(link))
        else: link.symlink_to(item,target_is_directory=item.is_dir())
sources = sorted((root/'Sources/CassiniSpectrogram').glob('*.swift'))
subprocess.run(['xcrun','swiftc','-O','-g','-swift-version','5','-parse-as-library',
    '-target',platform.machine()+'-apple-macos15.0','-whole-module-optimization',
    '-emit-module','-emit-object','-module-name','CassiniSpectrogram',
    '-emit-module-path',str(output/'CassiniSpectrogram.swiftmodule'),
    '-I',str(baseline),*map(str,sources),'-o',str(output/'CassiniSpectrogram.o')],check=True)
print('Compiled only candidate spectrogram SDK; original products untouched')
