# Conformance vectors

Twenty-five `.opus` files and one index, for answering "does my reader conform"
with something other than a person's judgement.

```bash
python3 run-conformance.py --adapter 'node adapters/adapter-js.mjs'
```

```console
20 pass, 3 warn, 0 fail, 2 skip, of 25
```

An adapter is any command that takes one file path and prints one observation
JSON object on stdout. Nothing else about your reader is assumed, so a reader in
any language needs about forty lines to join in. The four in `adapters/` are the
worked examples.

`index.json` names every vector, what it contains, which specification section it
exercises, and what a conforming reader must observe. It is the contract; this
directory is CC0 so you can vendor the whole thing.

## Profiles

A reader that never touches the audio cannot verify the audio digest, and should
not be marked down for it.

* `metadata` — reads the tags and the payload. Vectors 010 and 011 are skipped.
* `full` — also verifies `CASSINI_AUDIO_OPUS_SHA256` against the Opus packets.

## What the vectors cover

The happy path, and then every edge the specification either decides or has
quietly left open: plain audio with no metadata, multi-chunk payloads, padded
base64url, duplicate and missing chunks, chunk counts that disagree with what is
present, wrong payload and audio digests, lower- and mixed-case tag names,
unknown manifest members, an unknown major version, two transcripts, a transcript
id with no chunk set, and a comment header larger than the 61,440 octets
[RFC 7845 §5.2](https://www.rfc-editor.org/rfc/rfc7845#section-5.2) lets a reader
ignore. Vectors 023–025 cover word transcripts without origin labels,
selection of a second default entry, and ignoring old or unfamiliar labels.
Vector 026 combines those words with a native display and an unavailable
withdrawn cleanup entry; supported bodies must remain usable.

Vectors 018 and 021 are the pair worth reading first. They carry the same 49
comments with the same values in the same 68,032-octet packet, and differ only in
write order:

```
018-oversize-opustags     68,032 octets   25 comments past the limit, 11 of them descriptors
021-descriptors-first     68,032 octets    4 comments past the limit, all numbered chunks
```

Once a header is bigger than the window some chunk tags must fall past it. The
descriptors need not, and that is the whole argument for writing them first.
`build/mutate.py` asserts all four numbers when it generates the pair.

## Where the readers stand today

```
tools/cassini-extract.py            18 pass,  6 warn, 0 fail, 2 skip
tools/cassini-extract.py + digest   20 pass,  6 warn, 0 fail, 0 skip
tools/cassini-read.js               21 pass,  3 warn, 0 fail, 2 skip
cassini inspect (PR 276)            18 pass,  7 warn, 1 fail, 0 skip
```

A warning is a vector where the reader reported a different error code than the
suite names, or missed a SHOULD; the reader cannot be wrong there. A failure is
a reader disagreeing with a rule that exists.

Results were checked on 2026-09-07 against
[Cassini PR 276](https://github.com/codemyriad/gocassini/pull/276), based on fetched
main `e4856e9fac32c447d6c5e023681433319d7ea3c8`. Its only failure is the existing
tag/manifest disagreement policy in 011, reproduced on that starting main.
All four new vectors pass. See the
[implementation audit](../../design/format-simplification-2026-09-07.md#compatibility-and-cassini-follow-up).

The original 22 vectors retain their old metadata as compatibility coverage.
Regenerate only the new vectors with:

```bash
python3 build/simplified.py
python3 build/make-index.py
```

## The trust state

`expect.state` is the normative name from
[`SPEC.md`](../../SPEC.md)'s "Trust and integrity": one of `plain-audio`,
`unknown-cassini-format`, `invalid-cassini-metadata`, `unverified`,
`stale-audio`, `ok`. It is the thing two readers must agree on when they
describe one file.

Every adapter must report it. The `classification` / `payloadTrust` /
`audioTrust` triple is kept alongside it because it carries more detail.

Two rules the vectors lean on. A repeated load-bearing tag, anywhere, makes the
file `invalid-cassini-metadata` (005, 020, 022). A transcript body whose chunk
set is missing or fails its checks makes that transcript unavailable and leaves
the file's state alone (006): the reader reports the manifest's transcripts,
no word count for the broken one, and an error naming it.

How much work a reader did changes which state is correct, and the harness knows
this. A reader on the `metadata` profile never looks at the audio, so it cannot
reach `ok` or `stale-audio` and must say `unverified`. Where a vector only
requires `unverified`, a reader that did check the audio and found it sound may
report `ok`: it did strictly more than was asked. `stale-audio` is never
accepted in place of `unverified`, because that is a real disagreement rather
than extra diligence.

## What the harness refuses

The harness exits 2, and reports no pass, when the adapter declares a profile it
does not know, or when `index.json` asks for an expectation key or a `mustNot`
rule it does not implement. `state`, `classification`, `payloadTrust`,
`audioTrust` and `errors` cannot be listed in `omits`. A reader that reports an
error code other than the one the suite names, but reports one, gets a warning,
not a failure.

## Adding a vector

Keep it small: the largest here is 65 KB and most are under 4 KB. Add the file,
add its entry to `index.json` with the observation a conforming reader must make,
and say in `rationale` what would go wrong if nobody checked it.
