#!/usr/bin/env python3
"""Run a reader against the Cassini conformance suite.

    run-conformance.py --adapter 'node adapter.mjs' [--profile metadata]

The adapter is any command that takes one .opus path and prints one observation
JSON object on stdout. Nothing else about the reader is assumed, so this script
is the whole harness for a reader written in any language.

Exit 0 when every MUST assertion for the declared profile passed. Exit 1 on a
failed assertion; exit 2 when the suite or the adapter asks for something this
harness cannot check, which is never reported as a pass.
SPDX-License-Identifier: CC0-1.0"""
import argparse, hashlib, json, pathlib, shlex, subprocess, sys

# "state" is the normative name from SPEC.md; the rest is the detail the suite
# records alongside it. An adapter may report either or both.
SCALARS = ("state", "classification", "formatId", "manifestVersion", "manifestKind",
           "defaultTranscriptId", "payloadTrust", "audioTrust", "audioOpusSha256")
AUDIO_ONLY = {"audioTrust", "audioOpusSha256"}


def codes(items):
    return sorted(i["code"] for i in (items or []))


# Assertions an adapter may never opt out of: they are the whole point.
LOAD_BEARING = {"state", "classification", "payloadTrust", "audioTrust", "errors"}
PROFILES = ("metadata", "full")
EXPECT_KEYS = set(SCALARS) | {"transcriptIds", "speakerIds", "wordCounts", "errors",
                              "warnings", "sameContentAs", "mustNot"}
MUST_NOT = {"emit-transcript", "report-payload-verified", "report-audio-verified",
            "fail", "discard-transcript", "present-as-current",
            "sum-word-counts-across-transcripts"}


def refuse(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def validate_suite(doc):
    """Refuse to run a suite that asks for something this harness cannot check.
    A silently ignored expectation is a pass nobody earned."""
    for v in doc["vectors"]:
        for e in [v["expect"]] + v.get("alsoAcceptable", []):
            unknown = set(e) - EXPECT_KEYS
            if unknown:
                refuse(f"{v['id']}: expectation keys this harness does not check: {sorted(unknown)}")
            bad = set(e.get("mustNot", [])) - MUST_NOT
            if bad:
                refuse(f"{v['id']}: mustNot rules this harness does not implement: {sorted(bad)}")
        if not set(v["profiles"]) <= set(PROFILES):
            refuse(f"{v['id']}: unknown profile in {v['profiles']}")


def check(expect, obs, profile, index):
    """Return (failures, notes). A failure is a MUST; a note is a SHOULD."""
    fail, note = [], []
    omits = set(obs.get("omits") or ())
    if omits & LOAD_BEARING:
        return [f"omits may not include {sorted(omits & LOAD_BEARING)}"], []
    skipped = sorted(omits & set(expect))
    expect = {k: v for k, v in expect.items() if k not in omits}
    if skipped:
        note.append(f"not observable through this adapter: {skipped}")
    for key in SCALARS:
        if key not in expect:
            continue
        if key in AUDIO_ONLY and profile != "full":
            continue
        want, got = expect[key], obs.get(key)
        if key == "audioTrust" and got == "not-checked" and profile != "full":
            continue
        # The trust state depends on how much work the reader did.
        #
        # A metadata-profile reader never looks at the audio, so it cannot reach
        # 'ok' or 'stale-audio'; the spec says such a reader is conforming and
        # must report 'unverified'.
        #
        # Where a vector only requires 'unverified', a reader that did check the
        # audio and found it sound has done strictly more than asked, so 'ok' is
        # also correct. 'stale-audio' is not: that is a real disagreement.
        if key == "state":
            if profile != "full" and want in ("ok", "stale-audio"):
                want = "unverified"
            elif want == "unverified" and got == "ok":
                got = "unverified"
        if want != got:
            fail.append(f"{key}: expected {want!r}, got {got!r}")
    for key in ("transcriptIds", "speakerIds"):
        if key in expect and expect[key] != obs.get(key):
            fail.append(f"{key}: expected {expect[key]}, got {obs.get(key)}")
    if "wordCounts" in expect:
        # A reader may decode lazily, so it need not count every transcript. It
        # must count the default one, and every count it does report must be right.
        got = obs.get("wordCounts") or {}
        for tid, n in got.items():
            if tid in expect["wordCounts"] and expect["wordCounts"][tid] != n:
                fail.append(f"wordCounts[{tid}]: expected {expect['wordCounts'][tid]}, got {n}")
            elif tid not in expect["wordCounts"]:
                fail.append(f"wordCounts: reported an unexpected transcript {tid!r}")
        d = expect.get("defaultTranscriptId")
        if expect["wordCounts"] and d and d not in got:
            fail.append(f"wordCounts: no count for the default transcript {d!r}")
        elif expect["wordCounts"] and not d and not got:
            fail.append(f"wordCounts: expected {expect['wordCounts']}, got none")
    if "errors" in expect:
        want, got = codes(expect["errors"]), codes(obs.get("errors"))
        if want and not set(want) <= set(got) and not (got and want == ["decode-failed"]):
            # an adapter may report a more specific code than the suite names,
            # but it must report SOMETHING when the suite expects an error
            if not got:
                fail.append(f"errors: expected {want}, got none")
            else:
                note.append(f"errors: expected {want}, got {got}")
        if not want and got:
            fail.append(f"errors: expected none, got {got}")
    if "warnings" in expect:
        want, got = codes(expect["warnings"]), codes(obs.get("warnings"))
        missing = sorted(set(want) - set(got))
        if missing:
            note.append(f"warnings: none reported for {missing}")
    if expect.get("sameContentAs"):
        ref = index[expect["sameContentAs"]]
        for key in ("manifestVersion", "transcriptIds", "wordCounts", "speakerIds"):
            if key in omits:
                continue
            if key in ref["expect"] and ref["expect"][key] != obs.get(key):
                fail.append(f"sameContentAs {ref['id']}: {key} differs "
                            f"({ref['expect'][key]} vs {obs.get(key)})")
    for rule in expect.get("mustNot", []):
        if rule == "emit-transcript" and obs.get("wordCounts"):
            fail.append("mustNot emit-transcript: reader produced word counts "
                        f"{obs['wordCounts']} from an undecodable file")
        if rule == "report-payload-verified" and obs.get("payloadTrust") == "verified":
            fail.append("mustNot report-payload-verified")
        if rule == "report-audio-verified" and obs.get("audioTrust") == "verified":
            fail.append("mustNot report-audio-verified")
        if rule == "fail" and obs.get("classification") in ("damaged-metadata", "crash"):
            fail.append("mustNot fail: reader refused a readable file")
        if rule == "discard-transcript" and not obs.get("wordCounts"):
            fail.append("mustNot discard-transcript: reader dropped a transcript "
                        "whose only fault is that the audio no longer matches")
        if rule == "present-as-current" and (obs.get("classification") == "cassini"
                                             or obs.get("wordCounts")):
            fail.append("mustNot present-as-current: reader presented a version it "
                        "does not implement as if it understood it")
        if rule == "sum-word-counts-across-transcripts":
            # Alternative transcripts describe the SAME speech. Adding their word
            # counts together describes no meeting that ever happened. A summary
            # count must be one transcript's, not the sum of several.
            counts = obs.get("wordCounts") or {}
            reported = obs.get("totalWordCount")
            summed = sum(counts.values())
            if len(counts) > 1 and reported is not None and reported == summed \
                    and summed not in counts.values():
                fail.append("mustNot sum-word-counts-across-transcripts: reported "
                            f"{reported}, the sum of {counts}, for a meeting that "
                            "has neither that many words nor that many transcripts")
    if obs.get("classification") == "crash":
        fail.append(f"reader crashed: {codes(obs.get('errors'))}")
    return fail, note


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--profile", default=None, choices=["metadata", "full"])
    ap.add_argument("--suite", default="index.json")
    ap.add_argument("--json", action="store_true", help="emit results.json instead of a table")
    a = ap.parse_args()

    doc = json.loads(pathlib.Path(a.suite).read_text())
    validate_suite(doc)
    index = {v["id"]: v for v in doc["vectors"]}
    results, hard = [], 0
    for v in doc["vectors"]:
        blob = pathlib.Path(v["file"]).read_bytes()
        if hashlib.sha256(blob).hexdigest() != v["sha256"]:
            sys.exit(f"{v['file']}: does not match the sha256 in {a.suite}")
        proc = subprocess.run(shlex.split(a.adapter) + [v["file"]],
                              capture_output=True, text=True)
        try:
            obs = json.loads(proc.stdout)
        except json.JSONDecodeError:
            obs = {"classification": "crash",
                   "errors": [{"code": "adapter-produced-no-observation"}]}
        profile = a.profile or obs.get("profile", "metadata")
        if profile not in PROFILES:
            refuse(f"{v['file']}: adapter declared profile {profile!r}; "
                   f"this suite knows {list(PROFILES)}")
        if profile not in v["profiles"]:
            results.append((v["id"], "skip", ["not in profile " + profile]))
            continue
        fail, note = check(v["expect"], obs, profile, index)
        if fail and v.get("alsoAcceptable"):
            for alt in v["alsoAcceptable"]:
                alt_fail, alt_note = check(alt, obs, profile, index)
                if not alt_fail:
                    fail, note = [], alt_note + ["matched an alsoAcceptable outcome"]
                    break
        results.append((v["id"], "fail" if fail else ("warn" if note else "pass"),
                        fail + note))
        hard += bool(fail)

    if a.json:
        print(json.dumps({"adapter": a.adapter,
                          "results": [{"id": i, "status": s, "detail": d}
                                      for i, s, d in results]}, indent=2))
    else:
        for vid, status, detail in results:
            mark = {"pass": "PASS", "fail": "FAIL", "warn": "WARN", "skip": "skip"}[status]
            detail = [d for d in detail if not d.startswith("not observable")] \
                if status == "warn" and all(d.startswith("not observable") for d in detail) \
                else detail
            if status == "warn" and not detail:
                mark = "PASS*"
            print(f"{mark}  {vid}")
            for d in detail:
                print(f"        {d}")
        n = len(results)
        print(f"\n{sum(1 for _, s, _ in results if s == 'pass')} pass, "
              f"{sum(1 for _, s, _ in results if s == 'warn')} warn, "
              f"{hard} fail, "
              f"{sum(1 for _, s, _ in results if s == 'skip')} skip, of {n}")
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())
