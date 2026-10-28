# Bundled Opus encoder

Official libopus 1.6.1 source, BSD-3-Clause. Release and source SHA256 are
published at https://opus-codec.org/downloads/:

- https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
- SHA256 `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`

`scripts/fetch-opus.py` rechecks the source archive and compiles fresh ARM/Intel
slices with CMake, deployment target macOS15. DRED/OSCE are off. The verified
source's COPYING is shipped as LICENSE. A universal library is about1MiB; no
runtime download, network access or audio device is involved.

The app verifies its containing code signature/resource seal and the shipped
library hash before dlopen. Only the explicit offline test API accepts the hash
from a fresh source build. Compiled object/dylib caches are not reused by the build
script. `CassiniOpus` is an own GPL C ABI bridge using the public libopus API;
upstream source/headers are not modified or vendored in that target.

New encoding uses mono48kHz, VBR, complexity10, application audio, and D8's chosen
bandwidth/bitrate. The source pin is an implementation choice; it does not change
the shared match-source policy or its vectors.
