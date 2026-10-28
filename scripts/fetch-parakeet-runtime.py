#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build-time D16 fork runtime: verify both slices before assembling universal libraries."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('fetch_whistle', Path(__file__).with_name('fetch-whistle.py'))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    pin = json.loads((ROOT/'Parakeet/pins.json').read_text())
    origin = json.loads((ROOT/'Parakeet/UPSTREAM.json').read_text())
    for name, expected in origin['sha256'].items():
        f.checked(ROOT/name, expected)
    cache = args.cache or args.output.parent/'parakeet-downloads'
    cache.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    mac = pin['sherpa-onnx-go-macos']
    base = 'https://raw.githubusercontent.com/codemyriad/sherpa-onnx-go-macos/'+mac['commit']+'/'
    libraries = {
        'libsherpa-onnx-c-api.dylib': 'libsherpa-onnx-c-api.dylib',
        'libonnxruntime.dylib': 'libonnxruntime.dylib',
    }
    for source, target in libraries.items():
        slices = []
        for architecture in ['aarch64-apple-darwin', 'x86_64-apple-darwin']:
            name = 'lib/'+architecture+'/'+source
            metadata = mac['files'][name]
            binary = f.fetch(dict(name=name.replace('/', '_'),url=base+name,sha256=metadata['sha256']),cache)
            if binary.stat().st_size != metadata['size']:
                raise ValueError('Pinned runtime size mismatch: '+name)
            slices.append(str(binary))
        output = args.output/target
        subprocess.run(['xcrun','lipo','-create',*slices,'-output',str(output)],check=True)
        if set(subprocess.check_output(['xcrun','lipo','-archs',str(output)],text=True).split()) != {'arm64','x86_64'}:
            raise ValueError('Missing universal runtime slice')
    for name in ['pins.json','UPSTREAM.json','Sherpa-LICENSE','ONNXRuntime-LICENSE','ONNXRuntime-ThirdPartyNotices.txt']:
        shutil.copyfile(ROOT/'Parakeet'/name,args.output/name)
    hashes = {name: f.digest(args.output/name) for name in libraries.values()}
    (args.output/'unsigned-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
    print('Verified D16 cassini.8 ARM/Intel C API runtime, private ORT 1.28.1 and notices')


if __name__ == '__main__':
    main()
