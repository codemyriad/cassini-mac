#!/usr/bin/env python3
"""Exercise the real compiler using this workflow's exact/prefix cache policy."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[4]
ev=Path(os.environ['CASSINI_ABI_EVIDENCE']).expanduser().resolve();ev.mkdir(parents=True,exist_ok=True)
workflow=(root/'.github/workflows/ci-build.yml').read_text()
cache=workflow.split('path: .build\n',1)[1].split('      - name:',1)[0]
key=re.search(r'(?m)^\s+key: (.+)$',cache).group(1)
prefixes=re.findall(r'(?m)^\s+restore-keys: (.+)$',cache)
old='public struct Stamp {public let value:String;public init(_ value:String){self.value=value};public var orderingKey:String {value}}\n'
new='public struct Stamp {public let value:String;public let orderingKey:String;public init(_ value:String){self.value=value;self.orderingKey=value}}\n'
def cache_key(text):return key.replace('${{ steps.swiftpm_key.outputs.hash }}',hashlib.sha256(text.encode()).hexdigest())
matched=cache_key(old)==cache_key(new) or any(cache_key(old).startswith(p) for p in prefixes)
with tempfile.TemporaryDirectory(prefix='cassini-layout-probe-') as folder:
 work=Path(folder)
 (work/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"ABIProbe",targets:[.target(name:"Stamp"),.target(name:"Carrier",dependencies:["Stamp"]),.executableTarget(name:"client",dependencies:["Carrier"])])\n')
 for target in ('Stamp','Carrier','client'):(work/'Sources'/target).mkdir(parents=True)
 stamp=work/'Sources/Stamp/Stamp.swift';stamp.write_text(old)
 (work/'Sources/Carrier/Carrier.swift').write_text('import Stamp\npublic struct Carrier {public let stamp:Stamp;public let tracks:[Int];public init(){stamp=Stamp("test");tracks=Array(0..<8)}}\n')
 (work/'Sources/client/main.swift').write_text('import Carrier\nlet value=Carrier();print("TRACKS",value.tracks.count);precondition(value.tracks.count==8)\n')
 def run(name):
  with (ev/(name+'.log')).open('w') as log:return subprocess.run(['swift','run','--jobs','4','client'],cwd=work,stdout=log,stderr=subprocess.STDOUT,timeout=120)
 assert run('before').returncode==0
 stamp.write_text(new)
 # An input mismatch must be a cache miss. Simulate checkout+restore at the
 # same workspace, so the native build sees exactly what GitHub would reuse.
 if not matched:shutil.rmtree(work/'.build')
 result=run('changed-inputs')
 report={'crossSourceCacheRestored':matched,'nativeClientExit':result.returncode,'expectedTracks':8}
 (ev/'result.json').write_text(json.dumps(report,indent=2)+'\n')
 assert result.returncode==0,report
 assert 'TRACKS 8' in (ev/'changed-inputs.log').read_text(),report
 print(json.dumps(report))
