# doctor.sh → doctor-runner per-CHECK mapping

Baseline: `doctor.sh` at `881915d`, committed verbatim as
`tests/fixtures/doctor_sh_baseline.sh` (SHA256 in `.sha256`).

Purpose: prove no diagnostic check disappears when `doctor.sh` becomes a deprecation
stub. Section-level rows are insufficient because several sections contain multiple
independent checks, so each **check** and each **verdict site** is mapped separately.

Anchors are `doctor-runner` section numbers plus the check they perform. A cold
reviewer attests row by row; an unmapped row blocks the stub change.

## Section checks (11)

| # | baseline line | what it asserts | doctor-runner equivalent |
|---|---|---|---|
| S1 | 105 | ezgha service state (systemd/launchd) | §1 `ezgha.service = active` probe |
| S2 | 116 | docker daemon reachable | §2 docker daemon probe |
| S3 | 123 | colima VM status (macOS backend) | §3 colima VM probe |
| S4 | 190 | ezgha runtime state / daemon pid / recent loop errors | §4 ezgha runtime state |
| S5 | 240 | GitHub org runner fleet counts (online/offline/busy) | §5 GitHub org runner fleet |
| S6 | 267 | live managed containers on this host | §6 live docker containers |
| S7 | 280 | real job-execution proof from recent selftest runs | §7 real job-execution proof (leg-attributed) |
| S7b | 315 | optional `--prove` live canary dispatch + verify | §7b live canary |
| S8 | 354 | GitHub Actions queue health (tail age, queued count) | §8 queue health (`scripts/queue-health.sh`) |
| S9 | 369 | per-slot local execution proof via `docker top` | §9 per-slot activity truth |
| SV | 494 | final verdict aggregation | § verdict block |

## Verdict-effect sites (9) — the checks that change the exit code

These matter most: a dropped `CRITICAL+1` changes the exit code without changing any
message, so an emission-only inventory silently loses it.

| # | baseline line | predicate | doctor-runner equivalent |
|---|---|---|---|
| V1 | 496 | service not active → critical | § verdict: service/daemon gate |
| V2 | 497 | colima Stopped → critical | § verdict: backend gate |
| V3 | 502 | docker/container probe failed → critical | § verdict: docker gate |
| V4 | 505 | container count below expected → critical | § verdict: live-slot gate |
| V5 | 517 | (additional lifecycle critical) | § verdict: host-lifecycle gate |
| V6 | 526 | `REQUIRE_ROUTING_PROOF` and no runs at all → critical | § verdict: real-execution gate |
| V7 | 527 | `REQUIRE_ROUTING_PROOF` and no runs on fleet → critical | § verdict: real-execution gate (leg-attributed) |
| V8 | 529 | `--prove` requested but canary not OK → critical | § verdict: canary gate |
| V9 | 531 | queue tail exceeded → critical | § verdict: queue-tail gate |

## Reviewer attestation

- [ ] S1–SV: each surviving `doctor-runner` check is equivalent, or a difference is named
- [ ] V1–V9: each verdict effect is preserved, including its exit-code consequence
- [ ] No check is "intentionally dropped" without its own separate justification
- [ ] `.codex/commands/doctor.md` retargeted to `./doctor-runner`

Reviewer: ______________  Date: __________  Verdict: EQUIVALENT / GAPS NAMED
