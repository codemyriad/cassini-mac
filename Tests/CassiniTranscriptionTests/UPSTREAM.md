Shared D11 goldens copied verbatim from cassini-coordination/ux-draft/whistle,
including SHA256SUMS. D11.3 requires exact segments/text/count, identical
segment input SHA256 before allowing at most 80 ms word-time movement.
JFK audio is public-domain US federal government material.

Fixtures/jfk-received.opus is a plain Opus derivative of the public-domain JFK
fixture, made without capture: ffmpeg -i Goldens/jfk.wav -ac 1 -ar 48000 -c:a
libopus -b:a 32k -application audio Fixtures/jfk-received.opus. It exercises
Received import, offline Opus decode, the production pipeline and Speaker 1.

D11.4 mac-text-exceptions.json copied verbatim from coordination commit ed0bb85.
SHA256 5ec26f54bfc5e6e73f3c25e91f74aa37610b20b8f2aa43ea1f423bfca41a9b39.
Only the approved Mac word 37/segment 5/hash/pins exception is applied.
Original SHA256SUMS and all shared golden bytes remain unchanged.
