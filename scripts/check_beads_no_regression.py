#!/usr/bin/env python3
"""check_beads_no_regression.py — deletion/regression guard for .beads/issues.jsonl.

Compares the set of bead records at two git revisions (normally: PR merge-base/parent
commit vs PR head commit) and fails if either of these happened between them:

  1. DELETION — a bead `id` present at the parent commit is absent at the head commit.
  2. REGRESSION — a bead's `updated_at` timestamp at head is EARLIER than at parent
     for the same id (a tell-tale sign of a stale-DB full-file overwrite clobbering
     a concurrent session's newer edit).

Background/incident this guards against: a `beads flush` from a DB snapshot that
predates a sibling session's commits can silently rewrite issues.jsonl and drop or
revert beads that were added/updated concurrently. See bead jleechan-w528.

Usage:
    check_beads_no_regression.py <parent-revision> <head-revision> [--file PATH]
    check_beads_no_regression.py --parent-file PATH --head-file PATH

The first form shells out to `git show <rev>:<path>` to read each side. The second
form (used by the test suite / fixture proof) reads two local files directly, so the
core comparison logic can be exercised without needing a real git repo state.

Exit code 0 = pass (no deletions, no regressions). Exit code 1 = guard tripped.
Exit code 2 = usage/parse error (e.g. malformed JSONL, missing file).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Optional


DEFAULT_BEADS_PATH = ".beads/issues.jsonl"


def parse_jsonl_beads(text: str, source_label: str) -> dict[str, dict]:
    """Parse newline-delimited JSON bead records into {id: record}.

    Blank lines are skipped. A malformed line raises SystemExit(2) with a
    clear message pointing at the offending source + line number, rather than
    letting a raw JSONDecodeError traceback leak out.
    """
    beads: dict[str, dict] = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            print(
                f"::error::{source_label}: malformed JSON on line {lineno}: {exc}",
                file=sys.stderr,
            )
            raise SystemExit(2) from exc
        bead_id = record.get("id")
        if not bead_id:
            print(
                f"::error::{source_label}: line {lineno} has no 'id' field",
                file=sys.stderr,
            )
            raise SystemExit(2)
        beads[bead_id] = record
    return beads


def read_beads_from_file(path: str) -> dict[str, dict]:
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError as exc:
        print(f"::error::file not found: {path}", file=sys.stderr)
        raise SystemExit(2) from exc
    return parse_jsonl_beads(text, path)


def read_beads_from_git(revision: str, path: str) -> dict[str, dict]:
    result = subprocess.run(
        ["git", "show", f"{revision}:{path}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # A revision that doesn't have the file yet (e.g. beads file added in
        # this PR) is a legitimate "no beads existed yet" case, not an error.
        stderr = result.stderr.strip()
        if "does not exist" in stderr or "exists on disk, but not in" in stderr:
            print(
                f"::notice::{path} not present at {revision} — treating as empty baseline",
                file=sys.stderr,
            )
            return {}
        print(f"::error::git show {revision}:{path} failed: {stderr}", file=sys.stderr)
        raise SystemExit(2)
    return parse_jsonl_beads(result.stdout, f"{revision}:{path}")


# beads `updated_at` values commonly carry 9-digit nanosecond fractional
# seconds (e.g. "...T20:00:00.123456789Z"). `datetime.fromisoformat` only
# gained arbitrary-precision fractional-second support in Python 3.11; on
# older CPython builds (3.10 and earlier) it raises ValueError for anything
# other than exactly 3 or 6 digits, which would make parse_timestamp return
# None and silently skip the regression check. Truncate/pad the fractional
# part to exactly 6 digits (microseconds) ourselves so parsing is
# version-independent instead of relying on the runtime's Python version.
_FRACTIONAL_SECONDS_RE = re.compile(r"(\.\d+)")


def _normalize_fractional_seconds(value: str) -> str:
    def _truncate(match: "re.Match[str]") -> str:
        digits = match.group(1)[1:]  # strip leading '.'
        digits = (digits + "000000")[:6]
        return f".{digits}"

    return _FRACTIONAL_SECONDS_RE.sub(_truncate, value, count=1)


def parse_timestamp(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        # Normalize trailing 'Z' (Zulu) to an explicit UTC offset for fromisoformat.
        normalized = _normalize_fractional_seconds(value.replace("Z", "+00:00"))
        dt = datetime.fromisoformat(normalized)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        return None


def compare_beads(parent: dict[str, dict], head: dict[str, dict]) -> tuple[list[str], list[str]]:
    """Return (deletions, regressions) as lists of human-readable messages."""
    deletions: list[str] = []
    regressions: list[str] = []

    for bead_id, parent_record in parent.items():
        head_record = head.get(bead_id)
        if head_record is None:
            title = parent_record.get("title", "")
            deletions.append(f"{bead_id} (title: {title!r}) present at parent, MISSING at head")
            continue

        parent_ts = parse_timestamp(parent_record.get("updated_at"))
        head_ts = parse_timestamp(head_record.get("updated_at"))
        if parent_ts is not None and head_ts is not None and head_ts < parent_ts:
            regressions.append(
                f"{bead_id}: updated_at regressed from {parent_record.get('updated_at')} "
                f"(parent) to {head_record.get('updated_at')} (head)"
            )

    return deletions, regressions


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("parent_revision", nargs="?", help="git revision for the parent/merge-base commit")
    parser.add_argument("head_revision", nargs="?", help="git revision for the PR head commit")
    parser.add_argument("--file", default=DEFAULT_BEADS_PATH, help="path to issues.jsonl within the repo (git mode)")
    parser.add_argument("--parent-file", help="local file path for parent-side beads (fixture/test mode)")
    parser.add_argument("--head-file", help="local file path for head-side beads (fixture/test mode)")
    args = parser.parse_args(argv)

    if args.parent_file or args.head_file:
        if not (args.parent_file and args.head_file):
            parser.error("--parent-file and --head-file must be given together")
        parent_beads = read_beads_from_file(args.parent_file)
        head_beads = read_beads_from_file(args.head_file)
    else:
        if not (args.parent_revision and args.head_revision):
            parser.error("parent_revision and head_revision are required unless using --parent-file/--head-file")
        parent_beads = read_beads_from_git(args.parent_revision, args.file)
        head_beads = read_beads_from_git(args.head_revision, args.file)

    deletions, regressions = compare_beads(parent_beads, head_beads)

    if not deletions and not regressions:
        print(f"OK: {len(head_beads)} beads at head, {len(parent_beads)} at parent, no deletions or regressions")
        return 0

    if deletions:
        print(f"::error::{len(deletions)} bead(s) DELETED between parent and head:", file=sys.stderr)
        for msg in deletions:
            print(f"::error::  - {msg}", file=sys.stderr)
    if regressions:
        print(f"::error::{len(regressions)} bead(s) REGRESSED (stale updated_at) between parent and head:", file=sys.stderr)
        for msg in regressions:
            print(f"::error::  - {msg}", file=sys.stderr)

    print(
        "::error::This looks like a stale-DB full-file rewrite of .beads/issues.jsonl "
        "clobbering a concurrent session's beads. See bead jleechan-w528 for the incident "
        "this check guards against. Re-sync from the latest DB (br sync / reflush) before pushing.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
