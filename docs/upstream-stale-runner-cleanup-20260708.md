# Upstream Stale-Runner Cleanup — Research Synthesis for `s9d`

Date: 2026-07-08
Authors: parallel research fan-out (4 agents) under Track C of the `s9d` sidekick
Bead: `s9d` — Mac slot 2 stale-registration (offline-only, not 422 zombie)
Related: `qbl` reaper fix (PR #27, commit `d73dcff`) — handles offline+BUSY+422-locked class

## TL;DR

**The official `actions/runner` binary has NO client-side cleanup.** Registration deletion is wired only to the `config.sh remove` CLI command. ARCP does not delete the registration either. ARC has a finalizer that does, but the **422-with-container-already-exited case is an explicit known bug in ARC** — the pod is deleted and the registration is left dangling, with a comment that says "you'd probably need to manually delete the runner later." This is exactly the new class `s9d` is fighting.

**There is no upstream pattern to copy.** The ezgha daemon must build its own reaper, anchored on **local** state (container PID / `Runner.Worker` process), with explicit handling for 422 / 403 / 429 / `JobStillRunningError` patterns borrowed from ARC.

## 1. `actions/runner` (the binary) — no client-side cleanup

**Repo:** `actions/runner` @ `35e45850b519df66a669e2c91e0917804a33d0c7`

| File | Lines | Role |
|---|---|---|
| `src/Runner.Common/RunnerDotcomServer.cs` | L106–110 | `DeleteRunnerAsync` — `DELETE {entity}/runners/{id}` |
| `src/Runner.Common/RunnerDotcomServer.cs` | L112–177 | `RetryRequest` — only special-cases 404, not 422 |
| `src/Runner.Listener/Runner.cs` | L167–187 | `--remove` CLI dispatch (only runtime call to DELETE) |
| `src/Runner.Listener/Runner.cs` | L862–865 | ephemeral `DeleteLocalRunnerConfig()` — LOCAL ONLY, no server delete |
| `src/Runner.Listener/Configuration/ConfigurationManager.cs` | L527–618 | `UnconfigureAsync` — full remove flow |
| `src/Runner.Listener/CommandSettings.cs` | L228–235 | `GetRunnerName` — defaults to `Environment.MachineName` |
| `src/Runner.Listener/MessageListener.cs` | L154–168, L233–251 | Long-poll IS the heartbeat |

**`DeleteRunnerAsync` is invoked in exactly ONE place** — the `config.sh remove` CLI. It is never called at runtime:

```csharp
// src/Runner.Common/RunnerDotcomServer.cs:106
public async Task DeleteRunnerAsync(string githubUrl, string githubToken, ulong runnerId) {
    var githubApiUrl = $"{GetEntityUrl(githubUrl)}/runners/{runnerId}";
    await RetryRequest<...>(githubApiUrl, githubToken, RequestType.Delete, 3, "Failed to delete agent");
}
```

**`RetryRequest` does not special-case 422** (`RunnerDotcomServer.cs:167–171`). A 422 ("currently busy and cannot be removed") is retried 3× with 1–5 s backoff then thrown. ARC's behavior is the opposite — see §3.

**Ephemeral mode does NOT auto-delete the GitHub registration.** From `Runner.cs:862–865`:
```csharp
if (settings.Ephemeral && runOnceJobCompleted) {
    configManager.DeleteLocalRunnerConfig();
}
```
Local-only. Server-side cleanup is the GitHub service's TTL job (1 day ephemeral / 14 days non-ephemeral, per the 2022-08-03 changelog cited from `actions/runner#1364`).

**The "heartbeat" is a long-poll, not a heartbeat.** `grep -rn "Heartbeat" src/Runner.Listener/` → zero hits. `MessageListener.cs:233–251` holds an open `GetAgentMessage` HTTP request; GitHub flips the runner to `offline` when the long-poll terminates. When a container OOM-kills, GitHub learns via connection loss.

**The naming default is `Environment.MachineName` with no UUID suffix.** `CommandSettings.cs:228`. Containerized JIT-registration gets no auto-randomization. `ConfigurationManager.cs:335` throws `TaskAgentExistsException` on collision.

## 2. `actions/runner-container-hooks` (ARCP) — wrong hook for the problem

**ARCP does NOT delete the GitHub runner registration.** It only prunes Docker containers/networks (or k8s pods/secrets) that one Runner instance spawned for one job.

### Hook contract
`packages/hooklib/src/interfaces.ts`:
```ts
export enum Command {
  PrepareJob = 'prepare_job',
  CleanupJob = 'cleanup_job',
  RunContainerStep = 'run_container_step',
  RunScriptStep = 'run_script_step'
}
```
https://github.com/actions/runner-container-hooks/blob/HEAD/packages/hooklib/src/interfaces.ts#L1-L6

### `cleanupJob` is a Docker prune, not a GitHub unregister
`packages/docker/src/hooks/cleanup-job.ts:1-9`:
```ts
import { containerNetworkPrune, containerPrune } from '../dockerCommands/container'
export async function cleanupJob(): Promise<void> {
  await containerPrune()
  await containerNetworkPrune()
}
```
https://github.com/actions/runner-container-hooks/blob/HEAD/packages/docker/src/hooks/cleanup-job.ts#L1-L9

K8s twin (`packages/k8s/src/hooks/cleanup-job.ts:1-5`): `prunePods()` + `pruneSecrets()`.

### What ARCP never does
- `grep -rni "removeToken"` → 0 hits
- `grep -rni "/actions/runners"` → 0 hits
- No `net/http`, no `@octokit/rest`, no `google/go-github` anywhere
- No `Remove-Registration.ps1` / `cleanup.sh`
- No 422 / "already in use" detection

### Why this matters for ezgha
ARCP fires **inside the runner container between jobs**. Our runners ARE the containers, so ARCP can't run at container exit. Stale-registration cleanup must live in the ezgha daemon (the host), not in the container.

## 3. `actions/actions-runner-controller` (ARC) — has a 422-with-container-exited bug

**ARC has TWO reconcilers** with different 422 strategies. The legacy path (`actions.summerwind.net`) uses `google/go-github`; the modern path (`actions.github.com`) uses the `actions/scaleset` SDK.

### 3a. Legacy `RunnerReconcile`
`controllers/actions.summerwind.net/runner_graceful_stop.go:29-45` — `tickRunnerGracefulStop` → `annotatePodOnce(AnnotationKeyUnregistrationStartTimestamp)` → `ensureRunnerUnregistration` → `DeleteRunner`.

### 3b. **`Runner.Spec.DeleteRegistrationOnDelete` — NOT FOUND**
`grep -rn "DeleteRegistration" apis/ controllers/ github/` → 0 hits. `RunnerSpec` has only `Enterprise`, `Organization`, `Repository`, `Labels`, `Group`, `Ephemeral`, `Image`, `WorkDir`, `DockerdWithinRunnerContainer`, `DockerEnabled`, `DockerMTU`. **Cleanup is unconditional and inline in the finalizer chain.**

### 3c. `EphemeralRunnerReconciler` (`actions.github.com`)
`controllers/actions.github.com/ephemeralrunner_controller.go:79-399`:
1. On pod success → `r.Delete(ctx, &ephemeralRunner)` (line 393) → finalizer `runner-registration-finalizer` runs `cleanupRunnerFromService` → `deleteRunnerFromService` → `actionsClient.RemoveRunner`.
2. On race / failure → `deleteEphemeralRunnerOrPod` (line 401) calls `actionsClient.RemoveRunner` directly.

`controllers/actions.github.com/ephemeralrunner_controller.go:843-857`:
```go
func (r *EphemeralRunnerReconciler) deleteRunnerFromService(ctx context.Context, ephemeralRunner *v1alpha1.EphemeralRunner, log logr.Logger) error {
    client, err := r.GetActionsService(ctx, ephemeralRunner)
    if err != nil { return fmt.Errorf("failed to get actions client for runner: %w", err) }
    log.Info("Removing runner from the service", "runnerId", ephemeralRunner.Status.RunnerID)
    err = client.RemoveRunner(ctx, int64(ephemeralRunner.Status.RunnerID))
    if err != nil { return fmt.Errorf("failed to remove runner from the service: %w", err) }
    log.Info("Removed runner from the service", "runnerId", ephemeralRunner.Status.RunnerID)
    return nil
}
```
https://github.com/actions/actions-runner-controller/blob/HEAD/controllers/actions.github.com/ephemeralrunner_controller.go#L843-L857

### 3d. Pod-driven state machine (NOT GitHub-state driven)
`controllers/actions.github.com/ephemeralrunner_controller.go:317-398` — switches on `pod.Status.Phase == corev1.PodFailed`, `initContainerFailed`, `cs.State.Terminated.ExitCode`. Exit 0 → success path; exit 7 → `markAsOutdated`; non-zero non-7 → `deleteEphemeralRunnerOrPod`. **GitHub-side `busy`/`online`/`offline` is never inspected in this path.** ARC deletes on the **container's** state, not GitHub's — which is exactly the right pattern for ezgha's stale-registration reaper (trust local, not API).

### 3e. The 422-with-container-already-exited bug

**Legacy path** (`controllers/actions.summerwind.net/runner_graceful_stop.go:182-263`) — dispatch on `errRes.Response.StatusCode`:

```go
} else if ok, err := unregisterRunner(...); err != nil {
    if errors.Is(err, &gogithub.RateLimitError{}) {
        return &ctrl.Result{RequeueAfter: retryDelayOnGitHubAPIRateLimitError}, err
    }
    ...
    if errRes.Response.StatusCode == 403 {
        log.Error(err, "Unable to unregister due to permission error... ARC considers it as already unregistered...")
        return nil, nil
    }
    ...
    runnerBusy = errRes.Response.StatusCode == 422
    if runnerBusy && code != nil {
        log.V(2).Info("Runner container has already stopped but the unregistration attempt failed...", ...)
        return nil, nil
    }
    ...
    if runnerBusy {
        ...
        if ephemeral == "true" {
            return &ctrl.Result{}, nil
        }
        log.V(2).Info("Retrying runner unregistration because the static runner is still busy")
        return &ctrl.Result{RequeueAfter: retryDelay}, nil
    }
    return &ctrl.Result{}, err
}
```
https://github.com/actions/actions-runner-controller/blob/HEAD/controllers/actions.summerwind.net/runner_graceful_stop.go#L182-L263

**The 422+container-exited branch returns `nil, nil` — pod is deleted, registration is LEFT DANGLING.** ARC's own comment in the source acknowledges this is a known trade-off: "you'd probably need to manually delete the runner later." This is exactly the new class `s9d` is fighting.

**EphemeralRunner path** — `controllers/actions.github.com/ephemeralrunner_controller.go:436-447`:
```go
func (r *EphemeralRunnerReconciler) cleanupRunnerFromService(ctx context.Context, ephemeralRunner *v1alpha1.EphemeralRunner, log logr.Logger) (ok bool, err error) {
    if err := r.deleteRunnerFromService(ctx, ephemeralRunner, log); err != nil {
        if errors.Is(err, scaleset.JobStillRunningError) {
            log.Info("Runner job is still running, cannot remove the runner from the service yet")
            return false, nil
        }
        return false, err
    }
    return true, nil
}
```
https://github.com/actions/actions-runner-controller/blob/HEAD/controllers/actions.github.com/ephemeralrunner_controller.go#L436-L447

`scaleset.JobStillRunningError` is the ephemeral SDK's translation of 422. There's no equivalent of the 422+container-exited branch in the ephemeral path because the scale-set listener protocol handles it server-side.

### 3f. 403 / 429 / "already exists" handling

| Status / error | ARC behavior | Our pattern |
|---|---|---|
| 403 (permission) | "Already unregistered", proceed with pod delete | Treat as success |
| 422 (busy) + container running | RequeueAfter retryDelay (ephemeral: pass) | Requeue, do not delete container |
| 422 (busy) + container exited | Pod deleted, registration LEFT DANGLING | **The class we're fixing** — must re-check + re-DELETE |
| 429 (rate limit) | RequeueAfter retryDelayOnGitHubAPIRateLimitError | Backoff with secondary-limit ≥60s floor (existing per #24) |
| `scaleset.JobStillRunningError` | Passive wait | Same |
| `scaleset.RunnerExistsError` (name collision) | `getRunnerByName` → remove by ID before retry | Randomize the new name (see §5) |

### 3g. GitHub API wrapper
`github/github.go:204-223`:
```go
func (c *Client) RemoveRunner(ctx context.Context, enterprise, org, repo string, runnerID int64) error {
    enterprise, owner, repo, err := getEnterpriseOrganizationAndRepo(enterprise, org, repo)
    if err != nil { return err }
    res, err := c.removeRunner(ctx, enterprise, owner, repo, runnerID)
    if err != nil { return fmt.Errorf("failed to remove runner: %w", err) }
    if res.StatusCode != 204 { return fmt.Errorf("unexpected status: %d", res.StatusCode) }
    return nil
}
```
https://github.com/actions/actions-runner-controller/blob/HEAD/github/github.go#L204-L223

Dispatch by entity type (`github/github.go:334-342`):
```go
func (c *Client) removeRunner(ctx context.Context, enterprise, org, repo string, runnerID int64) (*github.Response, error) {
    if len(repo) > 0  { return c.Actions.RemoveRunner(ctx, org, repo, runnerID) }
    if len(org) > 0   { return c.Actions.RemoveOrganizationRunner(ctx, org, runnerID) }
    return c.Enterprise.RemoveRunner(ctx, enterprise, runnerID)
}
```
https://github.com/actions/actions-runner-controller/blob/HEAD/github/github.go#L334-L342

For EphemeralRunner, ARC does NOT hit `DELETE /actions/runners/{id}` at all — it goes through the scale-set `MessageSessionClient` SDK. ezgha does not have a scale-set listener, so we use the REST path with the ARC dispatch above.

## 4. `jleechanorg/agentwrapper` and `AgentWrapper/agentwrapper` — DO NOT EXIST

Both URLs return "Repository not found." The AgentWrapper org has only `agent-orchestrator` and `hermes-agent`. The closest near-name `jleechanorg/agent_wrapper` is `codex-tmux-wrapper` (a Codex CLI tmux proxy); zero GitHub-runner code.

**This repo IS the only GitHub-runner-management project in the jleechanorg org.** All five patterns we wanted to check there (stale-reaper, reconciler, registration/deletion API call, 422 handling, ticker) are NOT FOUND in the upstream ecosystem. The local pattern is novel by necessity.

## 4a. `actions/runner-images` — no runner deregistration (image-build only)

**Repo:** `actions/runner-images` @ `36308356ab25250efb4587c8799886c6996ac800`.

The `cleanup.sh` referenced from `images/ubuntu-slim/Dockerfile:57-60` is **build-time disk reclamation**, not runner deregistration:

```bash
#!/bin/bash -e
# helpers/cleanup.sh:1-13
# before cleanup
before=$(df / -Pm | awk 'NR==2{print $4}')
# clears out the local repository of retrieved package files
apt-get clean
rm -rf /tmp/*
rm -rf /root/.cache
```

- No `Remove-Runner.ps1` anywhere (`find . -iname "*remove*runner*"` → no hits).
- No `gh api DELETE /actions/runners/` in any `*.sh`, `*.ps1`, `*.psm1`, or `Dockerfile*`.
- No `runner-container-hooks` integration in the image build (`grep -rn "runner-container-hooks"` → 0 hits).
- No `ONBUILD` directive in the Dockerfile.

**Verdict:** `runner-images` ships zero runner-cleanup logic. The image is build-time only; lifecycle is the runner binary's job.

## 4b. `actions/toolkit` — no helper exists

**Repo:** `actions/toolkit` @ `0786132e6a1a4451c2d392bbbf481c2b172d4312`.

Package list: `artifact`, `attest`, `cache`, `core`, `exec`, `github`, `glob`, `http-client`, `io`, `tool-cache`. **No `runner` package.**

- `grep -rn "removeSelfHostedRunner\|deleteRunner\|/actions/runners/\|self_hosted_runners"` over `packages/**/*.ts` → zero hits.
- The `github` package is for Octokit-style issue/PR/comment APIs; the `http-client` package is a thin authenticated-fetch wrapper. Neither exposes any runner-registration helper.

**Verdict:** No `core.removeRunner()`-style helper exists. Tooling authors must call GitHub REST directly or use the Actions Service client (the latter only via `actions/scaleset`).

## 5. Concrete recommendation for `s9d` (5 bullets)

The `qbl` reaper already handles **offline + BUSY + 422-locked** (cancel the run, then DELETE). The new class is **offline + NOT-busy** (container died cleanly, registration persists, no 422 lock to clear). Pattern is to add a separate reaper on the daemon side, anchored on local state.

- **(a) New module `src/stale_runner_reaper.rs`** (or extend `src/queue_monitor.rs` with a `reap_stale_registrations` method). On each tick: enumerate configured runner slots, run `docker top <container> --filter label=ezgha=managed --no-trunc` for each. If a slot is **registered on GitHub** (i.e. `~/.config/ezgha/slot_assignments.toml` has a `runner_id` for that slot) but the corresponding container has **no `Runner.Worker` process** for ≥ N minutes (start with N=5, tune by watching false positives), call `octocrab.delete_self_hosted_runner_for_org(org, runner_id)` (or repo variant). Mirrors ARC's pod-driven state machine (§3d) — trust the container, not the API.

- **(b) Re-check the GitHub state before DELETE, with explicit 422 / 403 / 429 dispatch** (mirror ARC §3e/3f). On `DELETE /repos/{owner}/{repo}/actions/runners/{id}`:
  - `204` → success, clear the `runner_id` from `slot_assignments.toml`, schedule a fresh `ensure_count` cycle.
  - `403` → treat as already-unregistered (ARC's "permission error → already gone" pattern).
  - `404` → already gone; clear local state.
  - `422` (busy) → **RE-QUERY** the runner's `status` field. If `status=offline` on GitHub's side, the race window closed — retry DELETE once. If `status=online` and `busy=true`, an in-flight job is using the same runner_id (different container, different name); skip this slot, retry next tick. This is **stricter than upstream** (`actions/runner`'s `RetryRequest` does not special-case 422 at all).
  - `429` → existing secondary-limit ≥60s floor (per #24); back off.

- **(c) Use `--ephemeral` at JIT-config time** (`src/github.rs`, the `generate_jit_config` call path). The server-side TTL drops from 14 d → **1 d** for the registration if the runner ever died without cleanup, so a wedged slot self-heals by tomorrow even if every reaper tick is broken. Docs: https://docs.github.com/en/actions/hosting-your-own-runners/autoscaling-with-self-hosted-runners#using-ephemeral-runners-for-autoscaling. Trade-off: ephemeral mode is "one job then exit" semantics — confirm compatibility with the current JIT-config + multi-job-per-registration model; if incompatible, the qbl reaper PR #27's deploy lock can suppress ephemeral at registration time.

- **(d) Randomize the runner name on registration failure.** When `generate_jit_config` returns "already in use" (the 422 we're hitting in the new offline-NOT-busy class), retry with `<slot>-<random-hex>` instead of retrying with the same name. This is a **second line of defense** behind the reaper: even if the reaper hasn't caught up, the new container can register. Add a helper in `src/docker_backend.rs::allocate_slot` that takes a `name_already_in_use: bool` and regenerates. `actions/runner` has no equivalent — it either succeeds or throws `TaskAgentExistsException` at `ConfigurationManager.cs:335`.

- **(e) Adopt the upstream "stale-state cache" pattern from `actions/runner#3238`'s workaround.** After a successful reaper-DELETE on a slot, also `rm -f <slot's entry in> ~/.config/ezgha/slot_assignments.toml` and `docker rm -f <container>` if a half-up container exists. This is the local-config-wipe counterpart to `Runner.cs:862–865`'s `DeleteLocalRunnerConfig()` — without it, a future registration may still find stale local state. Wire it into the reaper's success path so each cycle of the loop leaves a clean slate.

**Net effect for Mac-1/6-stuck:** with (a) + (b), a slot where the container died but the GitHub registration is still there will be reaped within one tick (5 min) — directly addressing the new class. (c) is the long-stop safety net. (d) unblocks the next registration without waiting for the reaper. (e) prevents recurrence from a half-cleaned state. **No upstream pattern does all five**; this is the synthesis of ARC's finalizer-driven cleanup + ARC's pod-driven state machine + `actions/runner`'s local-config-wipe pattern, adapted to ezgha's Rust daemon.

## 6. Cross-cutting summary

| Concern | `actions/runner` | ARCP | ARC legacy | ARC ephemeral | runner-images | toolkit |
|---|---|---|---|---|---|---|
| Owns GitHub registration? | No (CLI-only DELETE) | No | Yes (graceful stop only) | Yes (finalizer + reconcile) | No | No |
| 422 handling | Not special-cased | n/a | status+container-state dispatch | `scaleset.JobStillRunningError` (30s requeue) | n/a | n/a |
| 422 + container exited | n/a | n/a | **Pod deleted, registration left dangling** | n/a (scale-set SDK handles) | n/a | n/a |
| 403 handling | n/a | n/a | "Already unregistered" | n/a | n/a | n/a |
| 429 handling | Not special-cased | n/a | Long requeue | Long requeue | n/a | n/a |
| State read | n/a | n/a | Pod phase + exit code | Pod phase + exit code | n/a | n/a |
| API | Manual `delete.sh` | None | `google/go-github` v52 → `DELETE /actions/runners/{id}` | `actions/scaleset` SDK → `_apis/distributedtask/pools/0/agents/{id}` | None | None |
| PreStop deregister? | n/a | n/a | No | No (finalizer does it) | n/a | n/a |
| Naming default | `Environment.MachineName` | n/a | n/a | scale-set managed | n/a | n/a |

**Architectural note on the two ARC paths.** ARC has TWO coexisting reaper patterns in one repo:

- **OLD `Runner` path** (`actions.summerwind.net`) — only graceful-stop drives `DELETE /actions/runners/{id}`. On accidental pod deletion the finalizer just removes itself; registration is left to the GitHub TTL. **This is exactly the failure mode `s9d` is fighting, and ARC has no fix for it.**
- **NEW `EphemeralRunner` / scale-set path** (`actions.github.com`) — controller-driven DELETE via the Actions Service admin URL `_apis/distributedtask/pools/0/agents/{id}` (NOT `api.github.com`). Finalizer-based; retries every 30s on `JobStillRunningError`. Requires the controller to hold an Actions Service admin URL (more privileged than a PAT or GitHub App token). The pod's `preStop` is NOT what drives the DELETE.

ezgha cannot use the Actions Service endpoint (no admin URL), so the relevant pattern is the OLD ARC path's `google/go-github` REST call — but applied eagerly on container exit, not only on graceful-stop.

## 7. Issue timeline (all verified via `gh search issues`)

| Date | Issue | Finding |
|---|---|---|
| 2021-09-21 | [actions/runner#1364](https://github.com/actions/runner/issues/1364) | "Auto-deregister failed ephemeral runners?" — canonical. **Closed 2023-03-20 without a runner-binary PR**; resolution was GitHub server-side TTL change. |
| 2022-08-03 | GitHub Changelog | TTL reduced 30 d → 1 d (ephemeral) / 14 d (non-ephemeral). **The only official cleanup mechanism.** |
| 2024-04-11 | [actions/runner#3238](https://github.com/actions/runner/issues/3238) | "Runner remove token" gap. Workaround: delete `.runner` then `./config.sh remove`. |
| 2025-03-24 | [actions/runner#3764](https://github.com/actions/runner/issues/3764) | Healthy runner auto-removed after VM shutdown. **Root cause unknown.** |
| 2026-03-06 | [actions-runner-controller#4397](https://github.com/actions/actions-runner-controller/issues/4397) | Stale `TotalAssignedJobs` after GitHub incident causes permanent over-provisioning. |
| 2026-06-01 | [actions-runner-controller#4513](https://github.com/actions/actions-runner-controller/issues/4513) | **OPEN** — `AutoscalingListener`/`EphemeralRunnerSet` retain stale image/labels after upgrade. |

## 8. Files & URLs

**actions/runner @ 35e4585:**
- `src/Runner.Common/RunnerDotcomServer.cs:106-110, 112-177`
- `src/Runner.Listener/Runner.cs:167-187, 567-573, 849-857, 862-865, 1137`
- `src/Runner.Listener/Configuration/ConfigurationManager.cs:259, 268, 272, 275-289, 317-321, 335, 375-378, 527-618, 640-652, 676-689`
- `src/Runner.Listener/CommandSettings.cs:32-54, 86, 228-235`
- `src/Runner.Listener/MessageListener.cs:154-168, 233-251, 336-342`
- `src/Misc/layoutroot/run.sh:13-60`
- `src/Misc/layoutroot/run-helper.sh.template:36-81`
- `docs/automate.md:65-78`

**actions/runner-container-hooks @ cf62bccb:**
- `packages/hooklib/src/interfaces.ts:1-6`
- `packages/docker/src/hooks/cleanup-job.ts:1-9`
- `packages/k8s/src/hooks/cleanup-job.ts:1-5`
- `packages/k8s/src/index.ts:34-49`

**actions/actions-runner-controller @ e06294f5:**
- `controllers/actions.summerwind.net/runner_graceful_stop.go:29-45, 182-263, 432-458`
- `controllers/actions.summerwind.net/runner_controller.go:65-103, 1278-1297`
- `controllers/actions.github.com/ephemeralrunner_controller.go:41-114, 317-398, 401-425, 436-447, 843-857`
- `controllers/actions.github.com/ephemeralrunnerset_controller.go:647-655, 670`
- `apis/actions.summerwind.net/v1alpha1/runner_types.go:31-83, 239-257`
- `apis/actions.github.com/v1alpha1/ephemeralrunner_types.go:186-203`
- `github/github.go:204-223, 334-342`
- `controllers/actions.github.com/multiclient/multi_client.go:44-58`

**actions/scaleset @ HEAD (ARC submodule):**
- `client.go:24` (`runnerEndpoint = "_apis/distributedtask/pools/0/agents"`)
- `client.go:749-769` (`RemoveRunner`)
- `client.go:102` (`"Runner is not finished yet, retrying in 30s"`)

**actions/runner-images @ 36308356:**
- `images/ubuntu-slim/Dockerfile:57-60`
- `images/ubuntu/scripts/build/cleanup.sh:1-13`

**actions/toolkit @ 0786132e:**
- (no relevant code)

**Confirmed NOT FOUND:**
- `jleechanorg/agentwrapper`, `AgentWrapper/agentwrapper` (repos don't exist)
- `actions/runner` `--remove-stale-runners-after` setting
- `actions/runner` ARCP/container-hooks integration
- `actions/actions-runner-controller` `Runner.Spec.DeleteRegistrationOnDelete` opt-out
- `actions/runner-controller` `Runner.Status.State` enum (only `Phase string`)
- `actions/runner-container-hooks` any GitHub REST/SDK call
- `actions/runner-images` any `Remove-Runner` script, `ONBUILD`, or `runner-container-hooks` integration
- `actions/toolkit` any `removeRunner` helper (no `runner` package)
