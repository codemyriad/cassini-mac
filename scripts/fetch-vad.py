#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build-time fetch of D11.1 Silero and the universal ONNX Runtime CPU library."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import tarfile
spec = importlib.util.spec_from_file_location('fetch_whistle', Path(__file__).with_name('fetch-whistle.py'))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
ORT_SHA = '49ae8e3a66ccb18d98ad3fe7f5906b6d7887df8a5edd40f49eb2b14e20885809'
SILERO_SHA = '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3'
MEMBERS = {
 'lib/libonnxruntime.1.23.2.dylib': ('libonnxruntime.1.23.2.dylib', '6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa'),
 'LICENSE': ('ONNXRuntime-LICENSE', '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'),
 'ThirdPartyNotices.txt': ('ONNXRuntime-ThirdPartyNotices.txt', 'e9e90971a8e75a9a8ac0c6412e29c1202d079998389915aa485f46c816c3b4cc'),
}
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--cache',type=Path);a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True);cache=a.cache or a.output.parent/'vad-downloads';cache.mkdir(parents=True,exist_ok=True)
 model=f.fetch(dict(name='silero_vad.onnx',url='https://raw.githubusercontent.com/snakers4/silero-vad/7e30209a3e901f9842f81b225f3e93d8199902b1/src/silero_vad/data/silero_vad.onnx',sha256=SILERO_SHA),cache)
 archive=f.fetch(dict(name='onnxruntime-osx-universal2-1.23.2.tgz',url='https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/onnxruntime-osx-universal2-1.23.2.tgz',sha256=ORT_SHA),cache)
 shutil.copyfile(model,a.output/'silero_vad.onnx')
 with tarfile.open(archive) as tar:
  for member,(name,sha) in MEMBERS.items():
   data=tar.extractfile('./onnxruntime-osx-universal2-1.23.2/'+member).read();target=a.output/name;target.write_bytes(data);f.checked(target,sha)
 shutil.copyfile(Path(__file__).resolve().parent.parent/'Whistle/Silero-LICENSE',a.output/'Silero-LICENSE')
 print('Verified Silero D11.1 and ONNX Runtime 1.23.2 universal CPU')
if __name__=='__main__':main()
