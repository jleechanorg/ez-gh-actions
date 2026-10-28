#!/usr/bin/env python3
"""install_scratch_migration.py — reproducibly move agent scratch producers off /tmp.

Bead: jleechan-0yic. Repo rule this exists to satisfy: "Reproducibility discipline
— no orphaned one-off fixes". The /tmp -> scratch migration was first applied live
to both hosts by hand; this installer is the git-tracked encoding of it, so a fresh
macOS or Linux machine reproduces the same state with one command.

Why the migration exists
------------------------
`/tmp` lives on the root filesystem that ezgha's runner-admission floor (30 GB on
Linux) protects. On 2026-10-28 jeff-ubuntu reached 14 GB free with 232 GB of stale
agent scratch in /tmp; ezgha correctly paused admission and the fleet drained from
20 to 3 runners. The Disk Magician scratch volume is a separate, sparse,
quota-bounded filesystem (`/Volumes/diskm-scratch` on macOS, `~/Scratch` on Linux),
so scratch growth there cannot silently starve CI admission. Producers are migrated
to resolve that root via `~/.claude/skills/scratch-space/scripts/scratch-dir.sh`,
falling back to `/tmp` only when no scratch volume is configured.

What each pattern does
----------------------
Every replacement keeps the script/docs runnable on a host without a scratch volume:

    SCRATCH="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh <purpose> 2>/dev/null || echo /tmp)"

Only workspace- and capture-scale producers are migrated. KB-scale temp files
(export exclusion lists, status markers, watchdog logs) intentionally stay in /tmp:
moving them buys no disk back and breaks documented tail paths.

Usage
-----
    ./scripts/install_scratch_migration.py                  # dry-run (default)
    ./scripts/install_scratch_migration.py --apply          # write changes
    ./scripts/install_scratch_migration.py --root /tmp/fixture --apply
    ./scripts/install_scratch_migration.py --json report.json

Exit codes: 0 = every pattern migrated or already migrated; 1 = drift/ambiguity
needs a human; 2 = bad usage or root.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

RESOLVER = "~/.claude/skills/scratch-space/scripts/scratch-dir.sh"

# expect="exact": the old snippet must appear exactly once (ambiguity is an error).
# expect="all":   replace every occurrence (used for legacy path tokens).
# absent_is_ok=True: a file that predates this snippet generation (some hosts ship an
#   older skill) is reported "not-applicable" instead of "drift" — it is not a local
#   edit that must be preserved, it is simply a generation that never had the snippet.
PATTERNS: list[dict] = [
    # ── scripts ──────────────────────────────────────────────────────────────
    {
        "file": "scripts/testerc.sh",
        "expect": "exact",
        "old": 'CAPTURE_DIR="/tmp/test_captures/$CAPTURE_TIMESTAMP"',
        "new": "# Scratch root per ~/.claude/skills/scratch-space/SKILL.md. Never a hardcoded\n"
               "# /tmp path: /tmp shares the root filesystem that ezgha's 30GB runner-admission\n"
               "# floor guards, so capture blobs there starve the CI fleet.\n"
               f'SCRATCH_ROOT="$({RESOLVER} test_captures 2>/dev/null || echo /tmp)"\n'
               'CAPTURE_DIR="$SCRATCH_ROOT/$CAPTURE_TIMESTAMP"',
    },
    # ── clonefix (modern guidance) ───────────────────────────────────────────
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,
        "old": '>    CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${repo_name}_clonefix_XXXXXX")"',
        "new": f'>    SCRATCH="$({RESOLVER} clonefix 2>/dev/null || echo /tmp)"\n'
               '>    CLONE_DIR="$(mktemp -d "${SCRATCH}/${repo_name}_clonefix_XXXXXX")"',
    },
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,
        "old": '`mktemp -d "${TMPDIR:-/tmp}/${repo_name}_clonefix_XXXXXX"`, then clone',
        "new": '`mktemp -d "${SCRATCH}/${repo_name}_clonefix_XXXXXX"` '
               f'(where `SCRATCH="$({RESOLVER} clonefix)"`, never `/tmp`), then clone',
    },
    # ── clonefix (legacy generation, still deployed on some hosts) ──────────
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,   # modern generation already migrated this heading
        "old": "### Phase 1: Clone Repository to /tmp",
        "new": "### Phase 1: Clone Repository to the scratch root",
    },
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "all",
        "absent_is_ok": True,   # modern generation never carried this legacy token
        "old": "/tmp/{repo_name}_clonefix_proof/",
        "new": f'"$({RESOLVER} clonefix)/{{repo_name}}_clonefix_proof/',
    },
    # ── clean room ───────────────────────────────────────────────────────────
    {
        "file": "skills/clean/SKILL.md",
        "expect": "exact",
        "old": 'description: "Clean Room Reproduction — Runs isolated E2E bug reproductions '
               'inside /tmp from a fresh repository state"',
        "new": 'description: "Clean Room Reproduction — Runs isolated E2E bug reproductions '
               'inside the resolved scratch root from a fresh repository state"',
    },
    {
        "file": "skills/clean/SKILL.md",
        "expect": "exact",
        "old": "`/clean` is used to reproduce issues from scratch in a fresh, isolated clean "
               "room directory inside `/tmp`. It guarantees that no side-effects or dirty "
               "local states affect the validity of the reproduction.",
        "new": "`/clean` is used to reproduce issues from scratch in a fresh, isolated clean "
               f"room directory inside the resolved scratch root (`$({RESOLVER} clean-room)`), "
               "never `/tmp` — a repo clone there lands on the root filesystem that ezgha's "
               "30 GB runner-admission floor guards. It guarantees that no side-effects or "
               "dirty local states affect the validity of the reproduction.",
    },
    {
        "file": "skills/clean/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,   # superseded by the git-probe generation below
        "old": "2. **Setup the Clean Room**: Create a fresh directory `/tmp/repro-cb-<issue_id>-<timestamp>`.",
        "new": '2. **Setup the Clean Room**: Create a fresh directory under the scratch root: '
               f'`"$({RESOLVER} clean-room)/repro-cb-<issue_id>-<timestamp>"`.',
    },
    # ── testing infrastructure ───────────────────────────────────────────────
    {
        "file": "skills/testing-infrastructure/SKILL.md",
        "expect": "exact",
        "old": "- Results saved to `/tmp/repo/branch/smoke_tests/`",
        "new": "- Results saved under the resolved scratch root: "
               f"`$({RESOLVER} smoke-tests)/<branch>/smoke_tests/` "
               "(never `/tmp` — see `scratch-space/SKILL.md`)",
    },
    # ── cross-host clone example ─────────────────────────────────────────────
    {
        "file": "skills/mac-remote/SKILL.md",
        "expect": "exact",
        "old": "ssh macbook 'git clone https://github.com/$GITHUB_REPOSITORY.git /tmp/your-project.com && \\",
        "new": 'ssh macbook \'SCRATCH="$(' + RESOLVER + ' sync 2>/dev/null || echo /tmp)" && \\\n'
               '  git clone https://github.com/$GITHUB_REPOSITORY.git "$SCRATCH/your-project.com" && \\',
    },
    {
        "file": "skills/mac-remote/SKILL.md",
        "expect": "exact",
        "old": "  cp -r /tmp/your-project.com/.claude/skills/ezgha-watchdog/* ~/.claude/skills/ezgha-watchdog/'",
        "new": '  cp -r "$SCRATCH/your-project.com/.claude/skills/ezgha-watchdog/"* ~/.claude/skills/ezgha-watchdog/\'',
    },
    # ── legacy command references (clone / baselines / validation dirs) ─────
    {
        "file": "skills/legacy-command-compatibility/references/clonefix.md",
        "expect": "exact",
        "old": "1. **Create unique clone directory**: `/tmp/{repo_name}_clonefix_{timestamp}`",
        "new": "1. **Create unique clone directory under scratch**: "
               f'`"$({RESOLVER} clonefix)/{{repo_name}}_clonefix_{{timestamp}}"` — never `/tmp`: '
               "a full clone is 1-7 GB on the root filesystem that ezgha's 30 GB "
               "runner-admission floor guards.",
    },
    {
        "file": "skills/legacy-command-compatibility/references/extended-library/clonefix.md",
        "expect": "exact",
        "old": "1. **Create unique clone directory**: `/tmp/{repo_name}_clonefix_{timestamp}`",
        "new": "1. **Create unique clone directory under scratch**: "
               f'`"$({RESOLVER} clonefix)/{{repo_name}}_clonefix_{{timestamp}}"` — never `/tmp`: '
               "a full clone is 1-7 GB on the root filesystem that ezgha's 30 GB "
               "runner-admission floor guards.",
    },
    {
        "file": "skills/legacy-command-compatibility/references/testuif.md",
        "expect": "exact",
        "old": 'if [ ! -d "/tmp/testuif_baselines" ]; then\n'
               "    mkdir -p /tmp/testuif_baselines\n"
               '    echo "Creating baseline screenshots for future comparisons"\n'
               '    mcp__playwright-mcp__browser_take_screenshot --path="/tmp/testuif_baselines/flask_baseline.png"',
        "new": f'SCRATCH="$({RESOLVER} testuif 2>/dev/null || echo /tmp)"\n'
               'if [ ! -d "$SCRATCH/testuif_baselines" ]; then\n'
               '    mkdir -p "$SCRATCH/testuif_baselines"\n'
               '    echo "Creating baseline screenshots for future comparisons"\n'
               '    mcp__playwright-mcp__browser_take_screenshot --path="$SCRATCH/testuif_baselines/flask_baseline.png"',
    },
    {
        "file": "skills/legacy-command-compatibility/references/extended-library/testuif.md",
        "expect": "exact",
        "old": 'if [ ! -d "/tmp/testuif_baselines" ]; then\n'
               "    mkdir -p /tmp/testuif_baselines\n"
               '    echo "Creating baseline screenshots for future comparisons"\n'
               '    mcp__playwright-mcp__browser_take_screenshot --path="/tmp/testuif_baselines/flask_baseline.png"',
        "new": f'SCRATCH="$({RESOLVER} testuif 2>/dev/null || echo /tmp)"\n'
               'if [ ! -d "$SCRATCH/testuif_baselines" ]; then\n'
               '    mkdir -p "$SCRATCH/testuif_baselines"\n'
               '    echo "Creating baseline screenshots for future comparisons"\n'
               '    mcp__playwright-mcp__browser_take_screenshot --path="$SCRATCH/testuif_baselines/flask_baseline.png"',
    },
    {
        "file": "skills/legacy-command-compatibility/references/testuif.md",
        "expect": "exact",
        "old": 'VALIDATION_DIR="/tmp/testuif_validation/$TIMESTAMP"',
        "new": f'SCRATCH="$({RESOLVER} testuif 2>/dev/null || echo /tmp)"\n'
               'VALIDATION_DIR="$SCRATCH/testuif_validation/$TIMESTAMP"',
    },
    {
        "file": "skills/legacy-command-compatibility/references/extended-library/testuif.md",
        "expect": "exact",
        "old": 'VALIDATION_DIR="/tmp/testuif_validation/$TIMESTAMP"',
        "new": f'SCRATCH="$({RESOLVER} testuif 2>/dev/null || echo /tmp)"\n'
               'VALIDATION_DIR="$SCRATCH/testuif_validation/$TIMESTAMP"',
    },
    {
        "file": "skills/legacy-command-compatibility/references/exportcommands.md",
        "expect": "exact",
        "old": 'export REPO_DIR="/tmp/claude_commands_repo_fresh"',
        "new": f'export SCRATCH="$({RESOLVER} exportcommands 2>/dev/null || echo /tmp)"\n'
               'export REPO_DIR="$SCRATCH/claude_commands_repo_fresh"',
    },
    {
        "file": "skills/legacy-command-compatibility/references/extended-library/exportcommands.md",
        "expect": "exact",
        "old": 'export REPO_DIR="/tmp/claude_commands_repo_fresh"',
        "new": f'export SCRATCH="$({RESOLVER} exportcommands 2>/dev/null || echo /tmp)"\n'
               'export REPO_DIR="$SCRATCH/claude_commands_repo_fresh"',
    },
    # ── second generation: git-based producers when the scratch volume cannot host git ─
    # The Linux scratch volume is fuse2fs, which rejects `open(O_CREAT|O_EXCL|O_RDWR, 0444)` -
    # exactly how git creates a loose object - so git clone/add/commit fail with EACCES there
    # while plain writes succeed (bead jleechan-tshq). The installer probes the host once
    # (see --scratch-git) and, when the probe fails, leaves these producers on ${TMPDIR:-/tmp}
    # rather than pointing a lane at a filesystem that cannot hold a repository.
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,
        "git_incapable_only": True,
        "old": '>    SCRATCH="$(' + RESOLVER + ' clonefix 2>/dev/null || echo /tmp)"\n'
               '>    CLONE_DIR="$(mktemp -d "${SCRATCH}/${repo_name}_clonefix_XXXXXX")"',
        "new": '>    # This host scratch volume cannot host a git repository (fuse2fs rejects the\n'
               '>    # 0444 loose-object create; bead jleechan-tshq), so clone into system temp.\n'
               '>    SCRATCH="${TMPDIR:-/tmp}"\n'
               '>    CLONE_DIR="$(mktemp -d "${SCRATCH}/${repo_name}_clonefix_XXXXXX")"',
    },
    {
        "file": "skills/clonefix/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,
        "git_incapable_only": True,
        "old": '1. **Create unique clone directory**: `"$(' + RESOLVER + ' clonefix)/{repo_name}_clonefix_{timestamp}"`',
        "new": '1. **Create unique clone directory**: `"${TMPDIR:-/tmp}/{repo_name}_clonefix_{timestamp}"` - this host scratch volume cannot host a git repository (fuse2fs rejects the 0444 loose-object create; bead jleechan-tshq).',
    },
    {
        "file": "skills/clean/SKILL.md",
        "expect": "exact",
        "absent_is_ok": True,
        "git_incapable_only": True,
        "old": '2. **Setup the Clean Room**: Create a fresh directory under the scratch root: `"$(' + RESOLVER + ' clean-room)/repro-cb-<issue_id>-<timestamp>"`.',
        "new": '2. **Setup the Clean Room**: Create a fresh directory `"${TMPDIR:-/tmp}/repro-cb-<issue_id>-<timestamp>"` - this host scratch volume cannot host a git repository (fuse2fs rejects the 0444 loose-object create; bead jleechan-tshq).',
    },
]

STATUS_ORDER = ["migrated", "would-migrate", "already-migrated", "missing",
                "not-applicable", "not-needed", "drift", "ambiguous"]


def probe_scratch_git_capable() -> tuple[bool, str, str]:
    """Can this host's scratch volume host a git repository?

    Returns (capable, root, detail). The Linux scratch volume is fuse2fs, which rejects
    `open(O_CREAT|O_EXCL|O_RDWR, 0444)` — the exact call git makes when creating a loose
    object — so `git init` succeeds there but `git add` fails with EACCES (bead
    jleechan-tshq). Probing `git add`, not just `git init`, is what distinguishes the two.
    Cleanup happens in Python (shutil), so no shell `rm -rf <variable>` is ever needed.
    """
    resolver = pathlib.Path.home() / ".claude/skills/scratch-space/scripts/scratch-dir.sh"
    if not resolver.exists():
        return False, "(none)", "no scratch resolver on this host"
    try:
        out = subprocess.run([str(resolver), "gitprobe"], capture_output=True, text=True, timeout=60)
        root = (out.stdout or "").strip()
    except Exception as exc:  # noqa: BLE001 - any failure means "do not trust it"
        return False, "(none)", f"resolver failed: {exc}"
    if not root:
        return False, "(none)", "resolver returned no path"
    tmp = ""
    try:
        pathlib.Path(root).mkdir(parents=True, exist_ok=True)
        tmp = tempfile.mkdtemp(prefix=".gitprobe.", dir=root)
        (pathlib.Path(tmp) / "f").write_text("x")
        for args in (["git", "-C", tmp, "init", "-q", "."], ["git", "-C", tmp, "add", "f"]):
            res = subprocess.run(args, capture_output=True, text=True)
            if res.returncode != 0:
                detail = (res.stderr or res.stdout or "git failed").strip().splitlines()
                return False, root, detail[0][:200] if detail else "git failed"
        return True, root, "git init+add succeeded"
    except Exception as exc:  # noqa: BLE001
        return False, root, str(exc)[:200]
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


def classify(path: pathlib.Path, pattern: dict) -> tuple[str, str]:
    """Return (status, detail) for one (file, pattern) pair without writing."""
    if not path.exists():
        return "missing", "file not present on this host"
    text = path.read_text()
    old, new = pattern["old"], pattern["new"]
    occurrences = text.count(old)
    if pattern["expect"] == "exact":
        if occurrences == 1:
            return "pending", "1 occurrence"
        if occurrences > 1:
            return "ambiguous", f"{occurrences} occurrences (refusing to guess)"
        if new in text:
            return "already-migrated", "already uses the scratch resolver"
        if pattern.get("absent_is_ok"):
            return "not-applicable", "this file predates this snippet generation"
        return "drift", "neither the old nor the new text is present (local edit?)"
    # expect == "all"
    if occurrences:
        return "pending", f"{occurrences} occurrences"
    if new in text:
        return "already-migrated", "already uses the scratch resolver"
    if pattern.get("absent_is_ok"):
        return "not-applicable", "this file predates this snippet generation"
    return "drift", "path token absent"


def apply_pattern(path: pathlib.Path, pattern: dict) -> None:
    text = path.read_text()
    if pattern["expect"] == "exact":
        path.write_text(text.replace(pattern["old"], pattern["new"], 1))
    else:
        path.write_text(text.replace(pattern["old"], pattern["new"]))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(pathlib.Path.home() / ".claude"),
                    help="Claude home to migrate (default: ~/.claude)")
    ap.add_argument("--apply", action="store_true", help="write changes (default is dry-run)")
    ap.add_argument("--json", dest="json_path", help="write a machine-readable report here")
    ap.add_argument("--scratch-git", choices=("auto", "yes", "no"), default="auto",
                    help="whether the scratch volume can host a git repository (default: probe)")
    args = ap.parse_args(argv)

    root = pathlib.Path(os.path.expanduser(args.root))
    if not root.is_dir():
        print(f"FATAL: root is not a directory: {root}", file=sys.stderr)
        return 2

    if args.scratch_git == "auto":
        scratch_git, scratch_root, scratch_detail = probe_scratch_git_capable()
    elif args.scratch_git == "yes":
        scratch_git, scratch_root, scratch_detail = True, "(forced)", "--scratch-git yes"
    else:
        scratch_git, scratch_root, scratch_detail = False, "(forced)", "--scratch-git no"
    print(f"scratch volume {scratch_root}: git-capable={scratch_git} ({scratch_detail})")

    results = []
    pending = 0
    problems = []
    for pattern in PATTERNS:
        if pattern.get("git_incapable_only") and scratch_git:
            results.append({"file": pattern["file"], "expect": pattern["expect"],
                            "status": "not-needed", "detail": "scratch can host git here"})
            continue
        path = root / pattern["file"]
        status, detail = classify(path, pattern)
        if status == "pending":
            if args.apply:
                apply_pattern(path, pattern)
                status, detail = "migrated", detail
            else:
                status = "would-migrate"
            pending += 1
        elif status in ("drift", "ambiguous"):
            problems.append((pattern["file"], status, detail))
        results.append({"file": pattern["file"], "expect": pattern["expect"], "status": status, "detail": detail})

    width = max((len(r["file"]) for r in results), default=10)
    mode = "apply" if args.apply else "dry-run"
    print(f"scratch migration ({mode}) root={root}")
    for r in results:
        print(f"  {r['status']:<15} {r['file']:<{width}}  {r['detail']}")
    tally: dict[str, int] = {}
    for r in results:
        tally[r["status"]] = tally.get(r["status"], 0) + 1
    print("summary: " + ", ".join(f"{k}={tally[k]}" for k in STATUS_ORDER if k in tally))
    if problems:
        print(f"\nNEEDS HUMAN ({len(problems)}): patterns present in the plan could not be applied "
              "safely. Rebase the pattern on the current file content; never force it.", file=sys.stderr)
        for f, status, detail in problems:
            print(f"  {status}: {f} — {detail}", file=sys.stderr)
    if args.json_path:
        pathlib.Path(os.path.expanduser(args.json_path)).write_text(
            json.dumps({"root": str(root), "mode": mode,
                        "scratch_git_capable": scratch_git, "scratch_root": scratch_root,
                        "results": results, "problems":
                        [{"file": f, "status": s, "detail": d} for f, s, d in problems]}, indent=1))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
