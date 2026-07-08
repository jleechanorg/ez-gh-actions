# Synthesis — `ez-gh-actions-s9d` (CORRECTED)

**Date:** 2026-07-08
**Inputs:** A (reaper context), B (mac stderr forensic), C (upstream research, VERIFIED), D (mac runtime inventory), Skeptic (Phase 3)
**Supersedes:** previous synthesis. Three claims retracted per Skeptic §1.

---

## 1. Root cause verdict (CORRECTED)

The s9d incident was a **transient offline-NOT-busy stale registration** (id 140294) for `ez-mac-runner-b-2` that blocked the Mac daemon's JIT-config retry loop for the slot-2 name (Track B §1 lines 22-32, §3 line 87-95). The blocker self-resolved at the registry layer: id 140294 returned HTTP 404 at 18:57:08Z (Track B §2 line 117, §5 line 121-124), and the daemon re-registered b-2 as id 140505 within the same serve-loop cycle (Track B §2 line 70, Track D §2 line 22-29, §6 line 135-136). **All 6 Mac slots are healthy with live `Runner.Worker` PIDs at 18:58:16Z** (Track D §4 line 105-114) and 6/6 online/busy in the API (Track D §6 line 132-139). The latent condition that produced the 140294 oscillation — offline-NOT-busy stale registration with no self-heal in the local daemon's code — has NOT recurred in the captured window but WILL recur the next time a slot dies cleanly and a sibling host re-uses the name before the registry evicts the orphan. The correct framing is **preventive, not reactive**: ship the 4th-sub-pass code change as defense in depth, and deploy `adafa19` (or successor) to Mac as part of the same change so the reaper wiring is at least present.

## 2. The latent condition (mechanical)

The current `release_stale_slots` orchestrator (`src/docker_backend.rs:265`) has three sub-passes per Track C §1 (verified) and Track A §2 line 47-58. The s9d class slips through all three:

- **Path 1 — `release_stale_slots_from_with_containers_for` (`src/docker_backend.rs:432`)**: predicate `live_ids` membership OR `offline && !busy && !local_container_names.contains(expected_name)` (Track C §1 line 23; Track A §2 line 47-58). **Frees the local slot but does NOT delete the GitHub registration.** The orphan reg remains on the org-runner list.
- **Path 2 — `offline_busy_owned_missing_container_slots` (`src/docker_backend.rs:493`)**: requires `busy=true` (Track C §1 line 24; Track A §2 line 49). The s9d class is `!busy` so this never fires. This is bead `qbl`'s 422-locked self-heal.
- **Path 3 — orphan forward sweep (`src/docker_backend.rs:374-396`)**: requires `!owned_ids.contains(r.id)` AND `offline && !busy` (Track A §2 line 47-58; Track C §1 line 25). For a slot where the slot-file row was overwritten with a new id after the orphan registered (Track D §2 line 22-29 shows this is exactly what happened — slot 2 = 140505, not 140294), the orphan's id is NOT in `owned_ids`, so the `!owned_ids` gate DOES permit deletion in principle. In practice during the 140294 window the daemon's serve loop never re-ran the orphan sweep fast enough relative to the JIT-config retry storm, and the daemon's JIT-config retry was short-circuited by the sibling-presume predicate on `busy=true` (Track B §1 line 27; Track B §5 line 124-125).

Result: orphan GitHub registration lingers; next JIT-config attempt with the same name hits `in use by an online/busy runner`. Path 1 needs to additionally call `github::remove_runner` when the slot it freed maps to a name whose registration is offline+!busy+container-dead.

## 3. Symptom vs latent condition

Per Skeptic Lens 1 (line 8-19) and Skeptic Lens 2 (line 21-33): the 1/6 → 6/6 → 1/6 cycling is **HISTORICAL, not live**. Track D §4 (line 105-114) and §6 (line 132-139) show all 6 Mac slots running with verified `Runner.Worker` PIDs and online/busy=true API status at 18:58:16Z. Track B §5 (line 121-124) confirms the offender id 140294 was evicted (404 at 18:57:08Z) before the daemon logged a positive registration for 140505 — meaning the eviction came first, the daemon's next serve-loop tick saw 140294 gone, and the JIT-config retry succeeded. The 61 stderr mentions of 140294 are **historical log lines from earlier in the day** (Track D §8 line 187, 192), not live failures. The latent condition (Path 1's failure to delete the GitHub registration) WILL recur but has not in the captured window.

## 4. Prioritized remediation

- **MIN** — Add a 4th sub-pass `offline_not_busy_owned_missing_container_registrations` between Path 1 and Path 3 in `release_stale_slots` (`src/docker_backend.rs:265`). Per verified Track C §3 bullet 1-2 (line 80-94): signature mirrors the qbl helper but takes the live runner list as primary key (path 1 has already released the slot, so the runner_id is no longer in `owned_ids` — must look up by name prefix match, not by slot-file id). Predicate: `runner.name.starts_with(prefix) && status==offline && !busy && !local_container_names.contains(name)`. On match: call `github::remove_runner` directly (no cancel/poll since no job to cancel). No new planner entry needed in `src/reaper.rs:plan_reaper_actions` (Track C §3 bullet 3 line 92) — extending the planner to accept `!busy` plans would re-introduce the "delete another host's registration" risk on every call site. **No grace window in v1** (Track C §3 bullet 4 line 94): path 1 already deletes the slot entry the moment the registration is offline+!busy+no-container, so latency between "slot released" and "registration deleted" is at most one reconciliation tick (30s). File a follow-up bead to add `last_active_on` to `RunnerInfo` (`src/github.rs:675`) for v2.
- **FULL** — MIN + grace window (`min_offline_seconds` based on `last_active_on`) + ARC-style idempotent `remove_runner` retry (verified Track C §2c: `runner_graceful_stop.go` accepts 422 and lets the next reconciler retry) + distinct stderr line for token-expiry (401) to surface the Mac token-refresh issue (Track D §3 line 58-70, Track C §4 risk 7 line 119).
- **DEPLOYMENT** — `cargo install --path .` on BOTH macbook AND jeff-ubuntu, then `launchctl kickstart -k gui/501/org.jleechanorg.ezgha` on Mac and `systemctl --user restart ezgha.service` on jeff. **Mac binary is `0.1.0-7f476ac-dirty` with NO reaper code at all** (Track A §3 line 70; Track D §1 line 9) — even the qbl wiring from `07fd091` is absent. The deploy-owner per `CLAUDE.md` single-writer rule (re-confirmed in Track A §1 line 17) owns steps 2-5; sub-agents and codex jobs commit + push only.

## 5. Recommended coding-bead content sketch for s9d (CORRECTED)

```
br update ez-gh-actions-s9d --description "$(cat <<'EOF'
Closes a latent gap in the ezgha reaper that produced today's Mac slot-2
oscillation (offline-NOT-busy stale registration id 140294). The symptom
self-resolved at the registry layer (140294 evicted, 140505 re-registered,
6/6 healthy at 18:58:16Z), but the underlying code path that let the
orphan linger is still in place. Next occurrence will recreate the same
serve-loop storm.

ROOT CAUSE: release_stale_slots (src/docker_backend.rs:265) has three
sub-passes. Path 1 (release_stale_slots_from_with_containers_for:432)
frees the local slot when offline+!busy+no-container but does NOT delete
the GitHub registration. Path 2 (offline_busy_owned_missing_container_slots:493)
requires busy=true (qbl class, not ours). Path 3 (orphan forward sweep
src/docker_backend.rs:374-396) requires !owned_ids AND offline+!busy
- fires only when the slot-file row no longer points at the orphan,
which is a race we lost today.

FIX: Add a 4th sub-pass offline_not_busy_owned_missing_container_registrations
between Path 1 and Path 3. Predicate: prefix match + status==offline +
!busy + !local_container_names.contains(name). On match: github::remove_runner.
No new reaper planner entry - extends the existing docker_backend orchestrator.
Mirror the qbl helper signature but take live_runners as primary key
(slot entry may be gone after Path 1 runs).

TESTS (in src/docker_backend.rs test module, alongside reclaim_zombie_locked_runner_*):
1. reclaim_offline_not_busy_owned_missing_container_registration_deletes_github_reg
   - live_runner {id:N, name:"ez-mac-runner-b-2", status:offline, busy:false}
   - container absent. Assert remove_runner called once with id N.
2. wrong-prefix negative: name="ez-mac-runner-c-2" must NOT delete.
3. container-still-running negative: local_container_names contains the name
   - must NOT delete.
4. online-runner negative: status==online - must NOT delete.
5. Regression for qbl: keep reclaim_zombie_locked_runner_cancels_then_deletes_on_success
   + reclaim_zombie_locked_runner_keeps_slot_when_job_never_leaves_in_progress green.
   Add a new test that exercises BOTH helpers on overlapping fixture state
   and asserts neither shadows the other.

ACCEPTANCE CRITERIA:
(a) Path 4 fires on offline+!busy+owned-prefix+no-container
(b) Path 2 still fires on 422-zombie class (regression)
(c) remove_runner is idempotent (ARC pattern - duplicate calls are no-ops, not errors)
(d) distinct stderr line emitted on 401 from remove_runner (token-expiry signal)
(e) Mac binary version embeds the new SHA after cargo install --path .

DEPLOYMENT: This is preventive, not reactive. The current 6/6 Mac state is
healthy. Deploy as part of normal Gate-0 with cargo install on BOTH macbook
AND jeff-ubuntu. Mac is currently on 7f476ac-dirty (no reaper code at all);
jeff is on 5f0374a (reaper wiring, pre-adafa19-false-positive-fix). Single-
writer rule applies: deploy-owner owns cargo install + restart, sub-agents
commit + push only.

FOLLOW-UP BEAD (file separately): add last_active_on to RunnerInfo
(src/github.rs:675) and thread min_offline_seconds into the new helper
for a v2 grace window. Not needed for s9d v1 per Track C §3 bullet 4.
EOF
)"
```

Demoted urgency language from "fixes an active outage" to "closes a latent gap that produced today's outage" (per Skeptic Lens 2 line 25-33 + §5 finding 4).

## 6. Cross-track consistency check (CORRECTED)

| claim | A | B | C (verified) | D | skeptic | consensus |
|---|---|---|---|---|---|---|
| Mac binary `0.1.0-7f476ac-dirty`, no reaper code | §3 L70 | — | — | §1 L9 | L1+L3 | **CONFIRMED** (3/3) |
| qbl reaper not deployed on Mac; jeff on `5f0374a` | §3 L66-70 | — | — | §1 L9 | L1+L3 | **CONFIRMED** |
| Orphan-reap gate = `!owned_ids && offline && !busy` | §2 L47-58 | — | §1 L25 | — | L1+L3 | **CONFIRMED** |
| Offender id 140294 = HTTP 404 at 18:57:08Z | — | §2 L117 | — | §6 L144 | L1+L2 | **CONFIRMED** |
| Mac fleet 6/6 healthy at 18:58:16Z with Worker PIDs | — | §2 L68-75 | — | §4 L105-114, §6 L132-139 | L1+L2 | **CONFIRMED** |
| 61 `140294` log lines are historical, not live | — | §5 L124 | — | §8 L187, L192 | L1+L2 | **CONFIRMED** |
| Token-refresh service idle on Mac | — | — | §4 R7 L119 | §3 L58-70 | L1+L3 | **CONFIRMED** |
| Path 1 frees slot but doesn't delete GH reg | — | — | §1 L23 | — | L3 | **CONFIRMED** (Lens 1 direct read `src/docker_backend.rs:475-506` + Track C §1) |
| ARC `runner_graceful_stop.go` idempotent | — | — | §2c L56-57 | — | — | **CONFIRMED** (verified) |
| actions/runner self-deregisters via `--ephemeral` | — | — | §2a L41-45 | — | — | **CONFIRMED** (verified) |
| soulteary is annotator-only, never deletes | — | — | §2d L63 | — | — | **CONFIRMED** (verified) |
| **Slot file held offender id 140294** (old synthesis) | §2 L60-62 (conditional) | implicit | — | **§2 L22-29 contradicts** | L1 **REFUTED** | **RETRACTED** |
| **Second occurrence on slot b-3** (old synthesis) | — | — | — | **§7 L169 contradicts** | L2 **REFUTED** | **RETRACTED** |
| **1/6 → 6/6 → 1/6 cycling is live** (old synthesis) | — | implicit | — | **§4+§6 contradict** | L2 **REFUTED** | **RETRACTED** |
| Track B "sticky-busy" root-cause framing | §2 L47-58 contradicts | §5 L125 | — | — | L1 **REFUTED** | **RETRACTED** |

## 7. Skeptic refutations acknowledged

1. **"Slot file held offender id 140294"** — RETRACTED. Track D §2 line 22-29: at 18:58:16Z the slot-file row for slot 2 was already `"140505"`, not `140294`. The orphan-sweep's `!owned_ids.contains` gate was not the live blocker. The latent condition exists but the slot-file premise was stale by the time of this investigation.
2. **"1/6 → 6/6 → 1/6 cycling is live"** — RETRACTED. Track D §4 (line 105-114) and §6 (line 132-139) show 6/6 healthy with live Worker PIDs and online/busy API status. The cycling was historical; the daemon is in stable clamping-output mode at 18:58:16Z.
3. **"Second occurrence on slot b-3"** — RETRACTED. Track D §7 line 169 explicitly says slot 3's 140506-vs-140511 is "slot-file drift on a working slot" — the daemon's JIT-config generation succeeds because the working name `ez-mac-runner-b-3` resolves to the current registry entry 140511. Bookkeeping lag, not a blocked registration. Recommend filing a SEPARATE scoped bead for slot-file drift, out of scope for s9d.
4. **Track B §5 "sticky-busy" framing** — RETRACTED. Track A §2 line 47-58 shows the orphan-reap gate is `!owned_ids.contains(r.id)`, not `busy=true`. Track B's framing describes the JIT-config retry path, not the orphan sweep; the two paths are conflated in Track B's conclusion. The synthesis does not import Track B's "sticky-busy" root cause.

## 8. Open questions for team-lead

1. **Should s9d be de-prioritized given current 6/6 health?** The 140294 incident self-resolved and has not recurred. A preventive fix has lower urgency than a reactive one. Recommendation: ship at next normal Gate-0, not emergency.
2. **Should the latent condition still be fixed preventively?** Yes — the code path that let 140294 linger is unchanged. The next sibling-host re-use of a name will recreate the storm. Cost is ~15-30 LOC + 5 tests. Worth it as defense in depth.
3. **Should slot-file drift on slot 3 (140506 vs 140511) get its own bead?** Track D §7 line 164-169 shows this is a different class — bookkeeping lag, not blocked registration. Recommend filing a separate, scoped bead for slot-file write-on-successful-reclaim.
4. **Token-refresh service idle on Mac (Track D §3 line 58-70)** — should this be its own bead? The App-token in `~/.config/ezgha/gh_token` is 25 minutes old at probe time; if the refresh timer doesn't fire, next expiry will cause 401 storms with no auto-recovery. Possibly higher urgency than s9d itself.
5. **Deploy scope** — Mac is on `7f476ac-dirty`, jeff on `5f0374a`, neither on `adafa19`. If s9d is merged, do we deploy MIN+adafa19 together, or just MIN? Per single-writer rule, the deploy-owner decides. Recommend: deploy MIN+adafa19 together so jeff also gets the false-positive fix hardened.

---

**Sources cited (track + line):**
- A §1 L17 (single-writer rule), §2 L47-58 (orphan-reap gate), §3 L66-70 (deploy state)
- B §1 L22-32 (140294 cluster), §2 L68-75 (API snapshot), §2 L117 (404), §5 L121-124 (eviction)
- C §1 L23-25 (three-path taxonomy), §2a L41-45 (actions/runner ephemeral), §2c L56-57 (ARC idempotent), §2d L63 (soulteary annotator), §3 bullets 1-4 L80-94 (verified recommendation)
- D §1 L9 (binary version), §2 L22-29 (slot file), §3 L58-70 (token-refresh), §4 L105-114 (Worker PIDs), §6 L132-139 (registry), §7 L164-169 (slot-file drift), §8 L187, L192 (historical log lines)
- Skeptic L1 L8-19 (claim 1 REFUTED), L2 L21-33 (claim 2+3 REFUTED), L3 L37-47 (code structure CONFIRMED), §3 L63-67 (3 refutations), §4 L71-73 (open disagreement)
