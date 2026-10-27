# PR #3 review dispositions (D6/D7)

The numbered findings refer to coordination REVIEWS/cassini-mac-3-findings.md.
LIBRARY-RULES R1–R10 govern derivation; earlier suggestions that conflict with
these rules are superseded. D7 prioritizes visible common-case parity and bugs.

| Findings | Disposition |
| --- | --- |
| 1, 12 | An explicit missing embedded id never falls back; reference.file must match the received original. Own embedded refs are unreadable. |
| 2, 6, 8, 23, 29 | R4 interruption sources only. Bad/missing/mismatched WAVs add diagnostics; completed stays completed. Unknown/out-of-range offsets count as display-zero; a track must match manifest rate/channels. Top-level gapFrames, source=recovered and ended=false are not extra interruption sources. |
| 3, 24, 25 | Quote is gated on usable words and status. Override whitespace/outer quotes normalized; blank ignored. |
| 4, 11, 13, 26 | Only speaking ids appear; first speaking determines ordering, colour and unnamed numbering. Received labels are retained except generic Speaker n labels. |
| 5, 21, 28 | Root resolves once; dangling root fails. Symlinked meeting dirs are skipped. Regular-file descriptor checks prevent link/FIFO reads from blocking. |
| 7, 14 | Schema-invalid metadata is ignored as a whole. Own regular transcript.json fallback still applies (R2/R3). |
| 9, 15 | R3 precedence: stored actionable error wins damage; otherwise transcript-damaged/null. Failed keeps stored error or derives transcribe-failed/Try again. Queued/running do not become damaged before words arrive. |
| 10, 16 | R8 consecutive time-sorted runs, no seam joining across interjections. Preserve straight quotes; collapse whitespace. |
| 17 | Exact integer half-up MB/GB rounding; GB switch uses rounded MB. Format v3 passes. |
| 18, 31 | Probe integer version first; newer app metadata is unsupportedVersion and metadataReadOnly, with own sidecar fallback. |
| 19 | Path-filtered FSEvents, 250 ms trailing / 2 s max debounce, root rebind and drop-event recovery. No WAV-growth rescan. Folder callbacks select incremental scans; async scan entry runs off UI thread. |
| 20 | Typed parsed successes/failures cached by device/inode/size/mtime_ns; full snapshots prune removed entries. No unchanged Opus rehash. |
| 22, 27 | Bad digest/unknown portable format cannot supply words; duration comes only from successful Opus stream digest, never manifest claims. R3 keeps explicit none as none; R9 then uses readable audio for write-down. |
| 30 | Strict sidecar required fields, nonempty speaker and ordered nonnegative integer times. |
| 32 | Trimmed title fallback chain ends in Untitled meeting; known starts sort first, unknown dates last by folded/exact title then UUID. |

Format v3 / states v2 are vendored unchanged. S-3a's trimmed main + R1–R9 fixtures
are now vendored with per-file SHA pins and an exact output adapter following
independent review. An input descriptor defect in Onboarding is reported in
coordination REPLIES-MAC.md; expected JSON is unchanged. D6.1 resolves the ETA question through the updated schema; no reader exception
remains. Fractional ends use exact numeric tokens / integer arithmetic, and
collections key meetings by folder basename when both prefixes share a UUID. The model remains read-only, including unsupported
metadata. No app scenes, desktop/browser/audio tests or recorder behavior change.
