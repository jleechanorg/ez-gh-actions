# Gitleaks Sweep - 2026-07-07

## High-priority security note

`worldarchitect.ai` had a currently tracked captured Google service-account credential in `roadmap/agent_001_command_frequency.json`. I redacted the tracked file in a normal forward commit on branch `sidekick/lane-h-gitleaks`; I did not rewrite history and did not rotate any credential. Because the captured credential looked like a real cloud service-account private key, a human owner should verify whether it is already revoked and rotate/revoke it if needed.

## Scope

Scanned repositories:

- `/home/jleechan/projects/ez-gh-actions-wt-lane-h` on branch `sidekick/lane-h`
- `/home/jleechan/projects/worldarchitect.ai-wt-lane-h` on branch `sidekick/lane-h-gitleaks`, created from `origin/main`

Commands run in each repo:

- Current working tree: `gitleaks detect --source . -v --no-git -r <reportfile>.json`
- Full git history: `gitleaks detect --source . -v -r <reportfile>.json`

Reports were written under `/tmp/gitleaks-lane-h/`. Secret values were not intentionally included in this report or commit messages.

## ez-gh-actions results

- Current working-tree scan before config: 0 findings.
- Full-history scan before config: 0 findings.
- Added `.gitleaks.toml` extending the built-in gitleaks rules.
- Added `.github/workflows/gitleaks.yml` so PRs and pushes to `main` run a current-tree gitleaks scan automatically.
- Verification after config: current-tree gitleaks scan passed with 0 findings.

## worldarchitect.ai results

- Current working-tree scan before cleanup/config: 56 findings.
- Full-history scan before cleanup/config: 3,549 findings.
- Real currently tracked secret fixed: captured Google service-account JSON/private key in `roadmap/agent_001_command_frequency.json`, replaced with `[REDACTED: captured service account credential removed 2026-07-07]`.
- Confirmed false positives allowlisted in `.gitleaks.toml`: test JWT/API-key fixtures, placeholder private-key examples, dummy Slack webhook documentation, public Firebase client configuration, and evidence/test IDs that match generic entropy rules.
- Added a `gitleaks` job to `.github/workflows/bead-jsonl-sort-check.yml`, renamed to `repository-hygiene`, so an existing every-PR lightweight workflow now also runs gitleaks automatically.
- Verification after cleanup/config: current-tree gitleaks scan passed with 0 findings, and `roadmap/agent_001_command_frequency.json` parses as valid JSON.

Full-history findings were recorded for exposure awareness only. Per task instructions, no history rewrite was attempted.

## Ambiguous or human-review items

- Firebase web API keys were treated as public client configuration and allowlisted, not redacted. A human owner may still want to verify those keys are appropriately restricted in Google Cloud/Firebase.
- The `worldarchitect.ai` full history contains many historical secret-shaped findings. This sweep intentionally did not remediate history; it only removed current tracked-file exposure and added CI guardrails.

## Commits and branches

- `ez-gh-actions`: branch `sidekick/lane-h`, commit `8dcd56f` added gitleaks config and CI.
- `worldarchitect.ai`: branch `sidekick/lane-h-gitleaks`, commit `8e3260ed07` redacted the current tracked secret, added config, and wired CI.
