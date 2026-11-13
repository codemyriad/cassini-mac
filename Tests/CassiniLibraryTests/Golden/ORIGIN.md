Format/status copies from merged cassini-ux a08ee0aff82d58448b42d9799747088ae01ce1ea (Phase 1 WP7, L-57); other resources retain their origins below:
- format-vectors.json v5: e418d48c7e551a90756699f42e939c7dd918f444deb302e4410af312afc32279 (76 cases).
- states-vectors.json v3: 2b946da58459452cb9fd17cacef58a3f10585a69142796cdd693e2f90fd9f497 (18 persisted cases + 1 transient importing entry vector).
- meeting.schema.json: D6.1 / D11.2 schema (nullable in-progress ETA; required names for source provenance); identical copy in the core Schema resource.
- LIBRARY-RULES.md: 415d866eb4a098400c76a3975969d9764bb70eed905726fbdcf7e90e42f85ce8 (cassini-ux 5e0c34e0f1bb390298dabdf4eedc494e933fd329).

Vectors are byte-for-byte copies, SHA256-checked. Do not adjust expected results locally.
S-3a (D7): main Library plus one case per R1–R9, pending the coordinator's fixture ping.

D16: meeting.schema.json and LIBRARY.md re-synced verbatim for optional transcript.model.
Schema SHA256 aed7704a3f6916d156f122cb60dd31c2cffe4a5701fcaebae691dd14dd5be03c.

D58/R81: meeting.schema.json re-synced verbatim from coordination ux-draft 3cb3ec2 (D56 voiceSource, silentTracks, lowDisk, D55 offsetsAssumedZero, captureRecord with documentation-only refusals); the core Schema resource copy is identical. Schema SHA256 b20f930cdd689c779a225939e2c35f2379c965d81454b54a80aa70478c7b679e.

R65 (D55): library-v2/ holds verbatim copies of cassini-coordination ux-draft/library-v2 at 287272a:
- name-vectors.json ea88624249550fabb92a2f5d7b03bfaa6424e8b10a7245431cf3c15da03709ff (164 cases)
- name-vectors-malformed.json 5de3b0b1effc01a0bb3cd1c106b88bbee2067373b62628c9c4337bcb47a3f6d9
- x-schema.json 214917c6e1f24936a9a97dc3b64e8fe6b4249733c67c985b11be67c2b0463f70
- MAPPING.md 692b8f7eb5fa4bd97642eea8a8d7ccc24d642bc9be9ca4250ae13bf2702dddd8

D70/D70.1: listen-by-speaker/ contains byte-for-byte copies from coordination
ux-draft/listen-by-speaker at 998a1b0, also used by GNOME PR #241 at 6969850.
- turns.json SHA256: 0c0d49a7f1d57f97b243d08c0558ab13506a39a93316a2e7506d228f21d75e29
- README.md SHA256: 499612b72cee5c64cb449f1797d3932a19c44e32a94711ebd8eb25a8d76c354b
The entirely synthetic English fixture is CC0-1.0; no real meeting content.
