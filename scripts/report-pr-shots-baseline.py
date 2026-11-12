#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Report exact vs fallback main ux-boards baseline status and commit age in shots_diff."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Callable

REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")


def escape_workflow_command(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def sanitize_inline(value: object) -> str:
    cleaned = " ".join(str(value).split())[:120]
    return re.sub(r"([\\`|\[\]()!*_#~<>])", r"", cleaned) or "unknown"


def commit_distance(repo: str, older_sha: str, newer_sha: str) -> int | None:
    if not REPO_RE.fullmatch(repo) or repo.split("/")[1] in {".", ".."}:
        raise ValueError(f"Invalid repository: {repo!r}")
    if not SHA_RE.fullmatch(older_sha) or not SHA_RE.fullmatch(newer_sha):
        raise ValueError("Invalid baseline commit SHA")
    try:
        res = subprocess.run(
            ["gh", "api", f"repos/{repo}/compare/{older_sha}...{newer_sha}"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        print(
            f"Baseline commit-age lookup failed ({older_sha[:7]}...{newer_sha[:7]}): {error}",
            file=sys.stderr,
        )
        return None
    if res.returncode != 0:
        err = res.stderr.strip() or f"gh api exited {res.returncode}"
        print(f"Baseline commit-age lookup failed ({older_sha[:7]}...{newer_sha[:7]}): {err}", file=sys.stderr)
        return None
    try:
        payload = json.loads(res.stdout)
    except json.JSONDecodeError as error:
        print(f"Baseline commit-age JSON parse failed: {error}", file=sys.stderr)
        return None
    ahead_by = payload.get("ahead_by")
    if type(ahead_by) is int and ahead_by >= 1:
        return ahead_by
    total_commits = payload.get("total_commits")
    if type(total_commits) is int and total_commits >= 1:
        return total_commits
    return None


def prepend_summary(summary_path: Path | None, markdown_header: str) -> None:
    if summary_path is None:
        return
    existing = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""
    sep = "\n\n" if existing and not existing.startswith("\n") else "\n" if existing else "\n"
    summary_path.write_text(markdown_header.rstrip("\n") + sep + existing, encoding="utf-8")


def report_baseline(
    changes_path: Path,
    summary_path: Path | None = None,
    compare_fn: Callable[[str, str, str], int | None] = commit_distance,
    out=sys.stdout,
) -> dict[str, object]:
    data = json.loads(changes_path.read_text(encoding="utf-8"))
    repo = data.get("repo")
    base = data.get("base")
    head = data.get("head")
    if not isinstance(repo, str) or not REPO_RE.fullmatch(repo) or repo.split("/")[1] in {".", ".."}:
        raise ValueError(f"Invalid repository in changes.json: {repo!r}")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise ValueError("Missing base/head metadata in changes.json")
    base_sha = base.get("sha")
    requested_sha = data.get("requested_base_sha", base_sha)
    if not isinstance(base_sha, str) or not SHA_RE.fullmatch(base_sha):
        raise ValueError(f"Invalid base.sha in changes.json: {base_sha!r}")
    if not isinstance(requested_sha, str) or not SHA_RE.fullmatch(requested_sha):
        raise ValueError(f"Invalid requested_base_sha in changes.json: {requested_sha!r}")

    no_baseline = bool(data.get("no_baseline"))
    base_run = sanitize_inline(base.get("run_id", "unknown"))
    base_runner = sanitize_inline(base.get("runner", "unknown"))
    head_runner = sanitize_inline(head.get("runner", "unknown"))

    if no_baseline:
        msg = (
            f"No main ux-boards baseline found for requested PR base {requested_sha[:7]} "
            "(run pending or artifact expired); diff contains after images only."
        )
        print(msg, file=out)
        print(f"::warning title=Missing UI screenshot baseline::{escape_workflow_command(msg)}", file=out)
        prepend_summary(
            summary_path,
            (
                "> [!WARNING]\n"
                f"> **Missing UI screenshot baseline:** No `main` `ux-boards` baseline was found for "
                f"requested PR base `{requested_sha[:7]}` (run pending or artifact expired); "
                "showing after images only."
            ),
        )
        return {
            "status": "missing",
            "commits_old": None,
            "base_sha": base_sha,
            "requested_base_sha": requested_sha,
        }

    if base_sha != requested_sha:
        age = compare_fn(repo, base_sha, requested_sha)
        if age is not None:
            unit = "commit" if age == 1 else "commits"
            age_label = f"{age} {unit} old"
            age_plain = f"{age} {unit} old (behind requested PR base {requested_sha[:7]})"
            age_md = f"**{age} {unit} old**, behind requested PR base `{requested_sha[:7]}`"
        else:
            age_label = "commit age unknown"
            age_plain = f"commit age unknown (behind requested PR base {requested_sha[:7]})"
            age_md = f"**commit age unknown**, requested PR base `{requested_sha[:7]}`"

        runner_plain = ""
        runner_md = ""
        if base_runner != head_runner:
            runner_plain = f" Baseline runner ({base_runner}) also differs from head runner ({head_runner})."
            runner_md = f" Baseline runner (`{base_runner}`) also differs from head runner (`{head_runner}`)."

        msg = (
            f"Fell back to older main ux-boards baseline {base_sha[:7]} (run {base_run}), "
            f"{age_plain}.{runner_plain}"
        )
        print(msg, file=out)
        print(
            f"::warning title=Fallback UI screenshot baseline ({age_label})::{escape_workflow_command(msg)}",
            file=out,
        )
        prepend_summary(
            summary_path,
            (
                "> [!WARNING]\n"
                f"> **Fallback UI screenshot baseline ({age_label}):** Requested PR base `{requested_sha[:7]}` "
                f"had no `ux-boards` artifact on `main`; fell back to `{base_sha[:7]}` "
                f"(run `{base_run}`, {age_md}).{runner_md}"
            ),
        )
        return {
            "status": "fallback",
            "commits_old": age,
            "base_sha": base_sha,
            "requested_base_sha": requested_sha,
        }

    msg = f"UI screenshot baseline matches requested PR base on main: {base_sha[:7]} (run {base_run}, 0 commits old)."
    print(msg, file=out)
    prepend_summary(
        summary_path,
        f"Baseline: exact `main` commit `{base_sha[:7]}` (run `{base_run}`, 0 commits old).",
    )
    return {
        "status": "exact",
        "commits_old": 0,
        "base_sha": base_sha,
        "requested_base_sha": requested_sha,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("changes_json", type=Path, help="Path to pr-shots changes.json")
    parser.add_argument(
        "--summary",
        type=Path,
        default=Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None,
        help="Path to GitHub step summary markdown file",
    )
    args = parser.parse_args(argv)
    report_baseline(args.changes_json, summary_path=args.summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
