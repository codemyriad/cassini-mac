Shared D11 goldens copied verbatim from cassini-coordination/ux-draft/whistle,
including SHA256SUMS. D11.3 requires exact segments/text/count, identical
segment input SHA256 before allowing at most 80 ms word-time movement.
JFK audio is public-domain US federal government material.

Fixtures/jfk-received.opus is a plain Opus derivative of the public-domain JFK
fixture, made without capture: ffmpeg -i Goldens/jfk.wav -ac 1 -ar 48000 -c:a
libopus -b:a 32k -application audio Fixtures/jfk-received.opus. It exercises
Received import, offline Opus decode, the production pipeline and Speaker 1.

D11.5 whistle-text-exceptions.json copied verbatim from coordination commit c12b02d.
SHA256 fde2d870983855c11833703772d3a5c0a0ad79f9b54752442b1d6131914f09a3.
The coordinator's shared exception permits only as/ask at word37, segment5, with
the same input/golden hashes and engine/model/library pins. It replaces the
Mac-only compatibility copy. Original SHA256SUMS and shared goldens are unchanged;
production recognizer output is never rewritten. Linux pins remain part of the
hash-bound shared manifest; Mac tests check the matching Mac engine pins.
