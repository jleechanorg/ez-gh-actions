# doctor.sh → doctor-runner per-CHECK mapping

Baseline: `doctor.sh` at `881915d`, committed verbatim as
`tests/fixtures/doctor_sh_baseline.sh` (SHA256 in `.sha256`).

Purpose: prove no diagnostic check disappears when `doctor.sh` becomes a deprecation
stub. Each **check** and each **verdict site** is mapped separately; section-level rows
would be insufficient because several sections contain multiple independent checks.

Every line number below was read from the baseline fixture, not inferred. An earlier
revision of this document contained two mislabelled verdict rows and omitted the
`SLOT_PROOF_CRITICAL` aggregation entirely; that was caught in review and is corrected
here.

## Section checks (11)

| # | baseline line | what it asserts | doctor-runner equivalent |
|---|---|---|---|
| S1 | 105 | ezgha service state | §1 ezgha service probe |
| S2 | 116 | docker daemon reachable | §2 docker daemon probe |
| S3 | 123 | colima VM status (macOS backend) | §3 colima VM probe |
| S4 | 190 | ezgha runtime state / daemon pid / loop errors | §4 ezgha runtime state |
| S5 | 240 | GitHub org runner fleet counts | §5 GitHub org runner fleet |
| S6 | 267 | live managed containers on this host | §6 live docker containers |
| S7 | 280 | real job-execution proof from recent selftests | §7 real job-execution proof (leg-attributed) |
| S7b | 315 | optional `--prove` canary dispatch + verify | §7b live canary |
| S8 | 354 | queue health (tail age, queued count) | §8 queue health via `scripts/queue-health.sh` |
| S9 | 369 | per-slot local execution proof via `docker top` | §9 per-slot activity truth |
| SV | 494 | final verdict aggregation | § verdict block |

## `CRITICAL` verdict sites (9)

These are the sites that increment the exit-code driver. A dropped one changes the
verdict without changing any message, so they are mapped individually.

| # | baseline line | predicate (verified) | doctor-runner equivalent |
|---|---|---|---|
| V1 | 496 | service state not `active` | § verdict: service gate |
| V2 | 497 | colima `Stopped` | § verdict: backend gate |
| V3 | 502 | **runners-online gate**: no runner with the configured prefix is `online` | § verdict: runners-online gate |
| V4 | 505 | container count below `EXPECTED_CONTAINERS` | § verdict: live-slot gate |
| V5 | 517 | **ensure_count loop gate**: `LOOP_FAILS > 3` and no healthy runners | § verdict: ensure_count-loop gate |
| V6 | 526 | `REQUIRE_ROUTING_PROOF` and no recent runs at all | § verdict: real-execution gate |
| V7 | 527 | `REQUIRE_ROUTING_PROOF` and no runs on the fleet | § verdict: real-execution gate (leg-attributed) |
| V8 | 529 | `--prove` requested but canary not OK | § verdict: canary gate |
| V9 | 531 | queue tail exceeded | § verdict: queue-tail gate |

**Corrections from review:** V3 was previously mislabelled "docker/container probe"
(it is the runners-online gate); V5 was previously mislabelled "(additional lifecycle
critical)" (it is the ensure_count loop gate).

## `SLOT_PROOF_CRITICAL` accumulation (previously missing)

A separate accumulator feeds `CRITICAL` at line **536**
(`CRITICAL=$((CRITICAL + SLOT_PROOF_CRITICAL))`). Its contributors:

| site | baseline line | what it counts | doctor-runner equivalent |
|---|---|---|---|
| P1 | 410 | slots DOWN (no container) | §9/verdict: `down` slot count |
| P2 | 415 | slots IDLE **while a fresh backlog exists** | §9/verdict: `idle-starved` slot count |
| P3 | 455 | remote (Mac) slots DOWN | §10/verdict: remote `down` slots |
| P4 | 459 | remote slots IDLE with backlog | §10/verdict: remote `idle-starved` slots |
| P5 | 487 | serve-loop starvation (respawn gap exceeds threshold) | § verdict: serve-loop/heartbeat gate |

Note P2/P4 are conditional on backlog; unparked idle slots are `info`, not critical —
`doctor-runner` preserves that distinction via its EXECUTING / IDLE-OK / IDLE-STARVED
model.

## Reviewer attestation

- [ ] S1–SV: each surviving `doctor-runner` check is equivalent, or a difference is named
- [ ] V1–V9: each `CRITICAL` verdict effect is preserved, including its exit-code consequence
- [ ] P1–P5: the `SLOT_PROOF_CRITICAL` accumulation is preserved
- [ ] No check is "intentionally dropped" without its own separate justification
- [ ] `.codex/commands/doctor.md`, `doctor-runner`, `README.md`, `install.sh` contain no stale `doctor.sh` invocation

Reviewer: ______________  Date: __________  Verdict: EQUIVALENT / GAPS NAMED
