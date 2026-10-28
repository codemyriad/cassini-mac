# Zstandard decoder

Unmodified decoder sources/headers from facebook/zstd 1.5.7, BSD-3-Clause (LICENSE).
https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
Archive SHA256: eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

Only common/decompress sources are compiled. No legacy formats, assembly or encoder.
Cassini's wrapper bounds the decoder window to 128 MiB and the raw output to the
manifest size; decoded bytes are independently hashed before publication.
