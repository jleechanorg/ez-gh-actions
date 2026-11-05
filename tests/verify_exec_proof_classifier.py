#!/usr/bin/env python3
"""Extract the section-7 execution-proof classifier from doctor-runner and
exercise it with realistic fixtures. Used to confirm the codex P0 at 609e288
(ordering: REMOTE_* assigned in section 10, read in section 7) is closed."""
import subprocess
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "doctor-runner"
lines = open(path).read().splitlines()

start = next(
    i for i, l in enumerate(lines)
    if l.strip().startswith("# Count a success as execution proof only")
)

# Walk forward tracking shell block depth so we capture the WHOLE if/elif/else.
# Extract by explicit boundary instead of brace counting: shell's inline
# `if ..; then X; fi` forms make naive depth counting stop early. The block
# starts at the comment marker and ends at the first line that both starts
# with "fi" at the loop-body indent and is followed by the `done < <(` that
# closes the read loop.
end = None
for i in range(start, len(lines)):
    if lines[i].strip() == "fi" and i + 1 < len(lines) and lines[i + 1].lstrip().startswith("done < <("):
        end = i
        break
if end is None:
    # fallback: last `fi` before the `done < <(` that closes the loop
    done_i = next(j for j in range(start, len(lines)) if lines[j].lstrip().startswith("done < <("))
    end = max(j for j in range(start, done_i) if lines[j].strip() == "fi")
if end is None:
    print("FAIL: could not find the closing fi")
    sys.exit(1)

block = "\n".join(l for l in lines[start:end + 1] if not l.strip().startswith("#"))

# The classifier now delegates the parked-leg decision to canonical helpers
# defined above section 7. Include them so the replay exercises the REAL rule
# rather than an undefined function.
# The canonical helpers are delimited by explicit sentinels so extraction cannot
# drift as their bodies change.
helper_start = next(
    i for i, l in enumerate(lines) if "BEGIN parked-leg helpers" in l
)
helper_end = next(
    i for i, l in enumerate(lines) if "END parked-leg helpers" in l
)
helpers = "\n".join(lines[helper_start:helper_end + 1])
block = helpers + "\n" + block
print(f"extracted classifier {end - start + 1} lines + helpers "
      f"{helper_end - helper_start + 1} lines")

cases = [
    # label, LOCAL_DISABLED, REMOTE_DISABLED, REMOTE_COUNT, local_pfx, remote_pfx, runner, expect, host_platform
    ("macos parked, Linux remote success counts", 1, 0, "", "ez-org-runner", "", "ez-runner-c-3", 1, "macos"),
    ("macos parked, Linux remote success counts (count set)", 1, 0, 20, "ez-org-runner", "ez-runner-c", "ez-runner-c-3", 1, "macos"),
    ("macos parked (configured ez-org-runner), its own legacy run rejected", 1, 0, 20, "ez-org-runner", "ez-runner-c", "ez-org-runner-1", 0, "macos"),
    ("linux active, Linux success", 0, 0, 0, "ez-runner-c", "ez-mac-runner-h", "ez-runner-c-3", 1, "linux"),
    ("linux host, remote Mac parked, Mac success rejected", 0, 1, 0, "ez-runner-c", "ez-mac-runner-h", "ez-mac-runner-h-1", 0, "linux"),
    ("non-fleet runner rejected", 0, 0, 0, "ez-runner-c", "ez-mac-runner-h", "gh-hosted-1", 0, "linux"),
    # codex P0 at 5b2e4f3: a Linux doctor with the Mac parked, exercising the
    # real production order where REMOTE_PREFIX is resolved from the platform
    # default before section 7 and REMOTE_COUNT is still empty.
    ("linux doctor + MAC parked, Mac success rejected", 0, 1, "", "ez-runner-c", "ez-mac-runner-h", "ez-mac-runner-h-1", 0, "linux"),
    ("linux doctor + MAC parked, Linux success counts", 0, 1, "", "ez-runner-c", "ez-mac-runner-h", "ez-runner-c-3", 1, "linux"),
    # codex P0 at d6234e3: a CONFIGURED custom prefix must still be recognised
    # as the parked leg, and ez-org-runner must not leak across both legs.
    ("macos parked with CUSTOM prefix ci-macos, its run rejected", 1, 0, "", "ci-macos", "", "ci-macos-1", 0, "macos"),
    ("macos parked with CUSTOM prefix ci-macos, Linux run counts", 1, 0, 20, "ci-macos", "ez-runner-c", "ez-runner-c-3", 1, "macos"),
    ("linux active, legacy ez-org-runner success counts", 0, 0, 0, "ez-org-runner", "ez-mac-runner-h", "ez-org-runner-2", 1, "linux"),
]

fail = 0
for label, LD, RD, RC, lp, rp, rn, exp, plat in cases:
    script = f"""set -euo pipefail
PLATFORM='{plat}'; LOCAL_DISABLED={LD}; REMOTE_DISABLED={RD}; REMOTE_COUNT={RC}
RUNNER_NAME_PREFIX='{lp}'; REMOTE_PREFIX='{rp}'
REAL_ON_FLEET=0; rid=1; rn='{rn}'; conc=success
ok(){{ :; }}; warn(){{ :; }}
{block}
printf '%s' "$REAL_ON_FLEET"
"""
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    got = r.stdout.strip()
    verdict = "PASS" if got == str(exp) else "FAIL"
    if verdict == "FAIL":
        fail += 1
    print(f"  [{label}] PROOF={got or 'ERR'} (expect {exp}) -- {verdict}")
    if r.returncode != 0:
        print(f"      stderr: {r.stderr.strip()[:200]}")

print("RESULT:", "PASS" if fail == 0 else f"FAIL ({fail} case(s))")
sys.exit(0 if fail == 0 else 1)
