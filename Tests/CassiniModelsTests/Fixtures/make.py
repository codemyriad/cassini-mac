#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Optional regeneration (zstd CLI required); CI uses the committed fixtures."""
from pathlib import Path
import hashlib,json,struct,subprocess
root=Path(__file__).resolve().parent;objects=[];files=[]
for name,raw in [('weights.bin',b'A'*(1<<20)+b''.join(hashlib.sha256(str(i).encode()).digest() for i in range(12288))),('tokens.txt',b'local fixture tokens\n')]:
 frames=[];entries=[]
 for offset in range(0,len(raw),262144):
  chunk=raw[offset:offset+262144]
  frame=subprocess.run(['zstd','-q','-c'],input=chunk,capture_output=True,check=True).stdout
  frames.append(frame);entries.append(struct.pack('<II',len(frame),len(chunk)))
 table=b''.join(entries)+struct.pack('<IBI',len(frames),0,0x8F92EAB1)
 compressed=b''.join(frames)+struct.pack('<II',0x184D2A5E,len(table))+table
 digest=hashlib.sha256(compressed).hexdigest();filename=name+'.zst';key=f'models/files/{digest}/{filename}'
 (root/filename).write_bytes(compressed)
 objects.append(dict(id=digest,key=key,filename=filename,url='http://127.0.0.1:1/'+key,size=len(compressed),sha256=digest,uncompressed_size=len(raw),uncompressed_sha256=hashlib.sha256(raw).hexdigest(),encoding='zstd-seekable',format_version='0.1.0'))
 files.append(dict(path=name,artifact=key,required=True))
(root/'manifest.json').write_text(json.dumps(dict(schema_version=2,base_url='http://127.0.0.1:1',published_at='2026-10-28',models=[dict(id='fixture-model',name='Test fixture',description='No actual model',license='CC0-1.0',source_url='https://example.invalid/never-fetch',source_sha256='a'*64,files=files)],artifacts=objects),indent=2)+'\n')
