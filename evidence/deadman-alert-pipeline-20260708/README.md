# Evidence bundle — alert pipeline dead-man's switch

PR: https://github.com/jleechanorg/ez-gh-actions/pull/23
Branch: `feature/deadman-alert-pipeline`
Commit: see PR head
Captured: 2026-07-08

## Files

- `red-phase-failure.txt` — `cargo test` output captured *before* the
  `DeadManState` and `deadman_threshold_seconds` implementation existed.
  Compile errors `E0609` (no field) and `E0433` (undeclared type) prove
  the tests were written first and the API did not yet exist.

- `green-phase-pass.txt` — same `cargo test` invocation after the
  implementation landed. `6 passed; 0 failed` for the new `deadman_*`
  tests; the 188 pre-existing tests filtered out by the name filter are
  confirmed in `full-suite.txt`.

- `full-suite.txt` — full `cargo test --bin ezgha` run with no filter:
  `194 passed; 0 failed`. This is the regression guarantee.

- `lint.txt` — `cargo fmt --check` clean (`FMT_OK`) and
  `cargo clippy --bin ezgha --all-targets -- -D warnings` clean
  (no warnings emitted).

## TDD cycle (required by /es evidence-standards)

Red → Green → Refactor:

1. **Red**: wrote 6 tests referencing `DeadManState` and
   `deadman_threshold_seconds`. Compile failed. Captured in
   `red-phase-failure.txt`.
2. **Green**: implemented `DeadManState` (in `src/alert.rs`),
   `AlertConfig::deadman_threshold_seconds` (in `src/config.rs`), and
   the serve-loop hook (in `src/main.rs`). All 6 new tests pass.
   Captured in `green-phase-pass.txt`.
3. **Refactor**: `cargo fmt` applied one auto-fix; `cargo clippy
   -D warnings` clean. Captured in `lint.txt`.

## Reproducing locally

```bash
git checkout feature/deadman-alert-pipeline
cargo test --bin ezgha alert::tests::deadman
cargo test --bin ezgha
cargo fmt --check
cargo clippy --bin ezgha --all-targets -- -D warnings
```

## What this evidence does NOT prove

- The dead-man self-test does not yet fire on the live production fleet
  (the operator must `cargo install --path .` and `systemctl --user
  restart ezgha.service` to deploy; per the project single-writer rule
  for steps 2–5, that deploy is the responsibility of the deploy-owner
  for the current session, not this PR author).
- The `~/.config/ezgha/config.toml` on `jeff-ubuntu` will use the
  default `deadman_threshold_seconds = 3600` after the operator adds an
  explicit `[alert]` block, or pick up the default automatically if
  their existing config has no `[alert]` section (the field is
  `#[serde(default)]`-initialized).
