#!/usr/bin/env bash
# doctor.sh — DEPRECATED. Use ./doctor-runner.
#
# This script is retired (AGENTS.md: "doctor.sh is LEGACY/BROKEN on docker 27+").
# It used to duplicate most of doctor-runner's checks against a different docker
# version and could report misleading verdicts on docker 27+.
#
# It is kept ONLY as a pointer so an old invocation fails loudly and legibly instead
# of silently doing nothing or running a stale check set. Every check it carried is
# covered by doctor-runner; the mapping is recorded in
# tests/fixtures/doctor_sh_check_mapping.md and its original source is preserved
# verbatim at tests/fixtures/doctor_sh_baseline.sh.
#
# Exit code 2 is deliberate: 0/1 mean healthy/unhealthy in doctor-runner, so a caller
# asserting those cannot mistake this stub for a real verdict.

cat >&2 <<'MSG'
doctor.sh is deprecated and performs no checks.

Use instead:

    ./doctor-runner            # authoritative fleet health check
    ./doctor-runner --detail   # verbose
    ./doctor-runner --prove    # dispatch a live canary

The original script is preserved at tests/fixtures/doctor_sh_baseline.sh and its
checks are covered by doctor-runner (see tests/fixtures/doctor_sh_check_mapping.md).
MSG

exit 2
