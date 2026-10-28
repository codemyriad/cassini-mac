#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the committed, decoder-only zstd snapshot without network access."""
import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
source=root/'Sources/CassiniZstd'
listed={}
for line in (source/'SHA256SUMS').read_text().splitlines():
 digest,name=line.split('  ',1);listed[name]=digest
 assert hashlib.sha256((source/name).read_bytes()).hexdigest()==digest,name
actual={str(p.relative_to(source)) for p in (source/'upstream').rglob('*') if p.is_file()}|{'LICENSE'}
assert actual==set(listed),(actual-set(listed),set(listed)-actual)
assert not (source/'upstream/compress').exists()
folder=root/'Cassini/Resources/Licenses';pin=json.loads((folder/'UPSTREAM.json').read_text())
assert hashlib.sha256((folder/'NOTICE.txt').read_bytes()).hexdigest()==pin['notice']['sha256']
assert (folder/'Zstandard-LICENSE.txt').read_bytes()==(source/'LICENSE').read_bytes()
print(f'Verified {len(listed)} pinned Zstandard decoder files and bundled notices; no network')
