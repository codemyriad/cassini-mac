#!/usr/bin/env python3
"""Independent stdlib ZIP fixtures for D96; no production ZIP code is used."""
import json, random, struct, sys, zipfile, zlib
from pathlib import Path
out, mode, audio = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]).read_bytes()
items = [('folder/English meeting.opus', audio)]
method = zipfile.ZIP_STORED
if mode == 'mixed': items += [('Duplicate.opus', audio), ('nested.zip', b'not opened'), ('readme.txt', b'English fixture')]
if mode == 'deflated': method = zipfile.ZIP_DEFLATED
if mode == 'unsafe': items += [('../late.opus', audio)]
if mode in ('encrypted', 'local-encrypted', 'crc'): items += [('Second.opus', audio)]
if mode == 'oversized': items = [('Too large.opus', audio * 2), ('Good.opus', audio)]
if mode in ('many', 'too-many'): items += [(f'{i}.txt', b'') for i in range(1999 if mode == 'many' else 2000)]
if mode in ('ratio', 'padded', 'forged-deflate'): method = zipfile.ZIP_DEFLATED; items = [('Large.opus', b'A' * 1_000_000)]
if mode == 'forged': items = [('one.opus', b'A' * 65536), ('two.opus', b'B' * 65536)]
if mode == 'symlink': items += [('link.opus', b'/private/should-not-be-opened')]
if mode == 'unicode-unsafe': items += [('alias.opus', audio)]
if mode == 'empty': items = [('nested.zip', audio), ('notes.txt', b'English text')]
with zipfile.ZipFile(out, 'w', compression=method) as archive:
    for name, data in items:
        info = zipfile.ZipInfo(name); info.compress_type = method
        if mode == 'symlink' and name == 'link.opus': info.create_system = 3; info.external_attr = 0o120777 << 16
        if mode == 'unicode-unsafe' and name == 'alias.opus':
            extra = b'\x01' + struct.pack('<I', zlib.crc32(name.encode())) + b'../escape.opus'
            info.extra = struct.pack('<HH', 0x7075, len(extra)) + extra
        archive.writestr(info, data)
data = bytearray(out.read_bytes())
directory = [i for i in range(len(data)) if data[i:i+4] == b'PK\x01\x02']
if mode in ('encrypted','local-encrypted'):
    p = directory[-1]
    if mode == 'encrypted': struct.pack_into('<H', data, p+8, struct.unpack_from('<H', data, p+8)[0] | 1)
    else:
        local = struct.unpack_from('<I', data, p+42)[0]
        struct.pack_into('<H', data, local+6, struct.unpack_from('<H', data, local+6)[0] | 1)
if mode == 'crc': data[directory[0]+16] ^= 1
if mode in ('forged', 'forged-deflate'):
    for p in directory: struct.pack_into('<I', data, p+24, 1)
if mode == 'padded':
    p = directory[0]; padding = b'\0' * 10000
    packed = struct.unpack_from('<I', data, p+20)[0]
    struct.pack_into('<I', data, 18, packed + len(padding))
    struct.pack_into('<I', data, p+20, packed + len(padding))
    end = data.rfind(b'PK\x05\x06')
    start = struct.unpack_from('<I', data, end+16)[0]
    struct.pack_into('<I', data, end+16, start+len(padding))
    data[p:p] = padding
out.write_bytes(data)
