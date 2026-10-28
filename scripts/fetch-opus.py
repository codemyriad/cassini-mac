#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build-time only: compile the pinned official libopus source for both Macs."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = dict(name='opus-1.6.1.tar.gz', url='https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz',
              sha256='6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1')
spec = importlib.util.spec_from_file_location('fetch_whistle', ROOT/'scripts/fetch-whistle.py')
fetch = importlib.util.module_from_spec(spec); spec.loader.exec_module(fetch)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    cache = (args.cache or output.parent/'opus-downloads').resolve(); cache.mkdir(parents=True, exist_ok=True)
    archive = fetch.fetch(SOURCE, cache)
    # Only the source archive is reused, after SHA verification. Build fresh so
    # stale or modified object/dylib caches cannot become trusted shipped code.
    with tempfile.TemporaryDirectory(prefix='opus-build-',dir=cache) as temporary:
        temporary = Path(temporary)
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                path = (temporary/member.name).resolve()
                if temporary not in path.parents or member.issym() or member.islnk():
                    raise ValueError('Unsafe source archive member')
            source.extractall(temporary)
        source = temporary/'opus-1.6.1'
        slices = []
        for arch, processor in [('arm64','aarch64'),('x86_64','x86_64')]:
            build = temporary/arch
            log = output/('build-'+arch+'.log')
            with log.open('w') as stream:
                command = ['cmake','-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release',
                           '-DCMAKE_SYSTEM_NAME=Darwin','-DCMAKE_SYSTEM_PROCESSOR='+processor,
                           '-DCMAKE_OSX_ARCHITECTURES='+arch,'-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
                           '-DCMAKE_INSTALL_NAME_DIR=@rpath','-DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON',
                           '-DOPUS_BUILD_SHARED_LIBRARY=ON','-DOPUS_BUILD_TESTING=OFF','-DOPUS_BUILD_PROGRAMS=OFF',
                           '-DOPUS_DRED=OFF','-DOPUS_OSCE=OFF']
                print('Building pinned libopus 1.6.1:',arch,flush=True)
                for command in [command,['cmake','--build',str(build),'--parallel','4']]:
                    result = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT)
                    if result.returncode:
                        stream.flush(); print('\n'.join(log.read_text().splitlines()[-30:]))
                        raise RuntimeError('libopus build failed: '+arch)
            slices.append((build/'libopus.0.dylib').resolve())
        pending = output/'libopus.0.pending.dylib'
        subprocess.run(['xcrun','lipo','-create',*map(str,slices),'-output',str(pending)],check=True)
        actual = subprocess.check_output(['xcrun','lipo','-archs',str(pending)],text=True).split()
        assert set(actual) == {'arm64','x86_64'}, actual
        pending.replace(output/'libopus.0.dylib')
        shutil.copyfile(source/'COPYING',output/'LICENSE')
    pins = dict(version='1.6.1',source=SOURCE,architectures=['arm64','x86_64'],deploymentTarget='15.0',
                dred=False,osce=False,license='BSD-3-Clause')
    (output/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    (output/'unsigned-sha256.json').write_text(json.dumps({'libopus.0.dylib':fetch.digest(output/'libopus.0.dylib')},indent=2)+'\n')
    print('Verified libopus 1.6.1 source; built arm64 + x86_64')

if __name__ == '__main__': main()
