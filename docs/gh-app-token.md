# GitHub App Installation Tokens

`ezgha` shells out to `gh api` for runner registration, runner listing, cleanup,
and canary workflow calls. Without an explicit token, `gh` can fall back to the
interactive user's stored credentials, which puts daemon traffic in the same
rate-limit bucket as human work. The token refresh job mints short-lived GitHub
App installation tokens and writes the current token to:

```text
~/.config/ezgha/gh_token
```

The daemon reads that file before each `gh` invocation and exports it as
`GH_TOKEN` for the child process, so a refreshed token is picked up without
restarting `ezgha`.

## Prerequisites

Place the GitHub App private key on each host and restrict it to the user
running `ezgha`:

```bash
mkdir -p ~/.config/ezgha
install -m 600 /path/to/private-key.pem ~/.config/ezgha/app_private_key.pem
```

The default app settings are:

```text
App ID: 4245332
Installation ID: 145172957
Org: jleechanorg
Private key path: ~/.config/ezgha/app_private_key.pem
```

Override those values by passing `--app-id`, `--installation-id`, or `--key-path`
to `scripts/refresh_gh_app_token.sh`.

## Linux systemd user timer

Scripts are never exec'd from the repo/worktree checkout — `install.sh`
copies `scripts/*.sh` (and `mint_gh_app_token.py`, a sibling helper) to the
stable user-scope location `~/.local/libexec/ezgha/` first, then renders the
unit with `@SCRIPTS_DIR@` pointing there (not `@REPO_PATH@`), so a deleted
worktree can never silently take a scheduled job down (bead
`ez-gh-actions-sa1t`). To install by hand:

```bash
scripts_dir="${HOME}/.local/libexec/ezgha"
mkdir -p ~/.config/systemd/user "${scripts_dir}"
install -m 0755 scripts/refresh_gh_app_token.sh scripts/mint_gh_app_token.py "${scripts_dir}/"
sed "s|@SCRIPTS_DIR@|${scripts_dir}|g" \
  systemd/ezgha-token-refresh.service \
  > ~/.config/systemd/user/ezgha-token-refresh.service
sed "s|@SCRIPTS_DIR@|${scripts_dir}|g" \
  systemd/ezgha-token-refresh.timer \
  > ~/.config/systemd/user/ezgha-token-refresh.timer

systemctl --user daemon-reload
systemctl --user start ezgha-token-refresh.service
systemctl --user enable --now ezgha-token-refresh.timer
```

The timer runs 2 minutes after boot and then every 45 minutes.

## macOS launchd

The template lives at `launchd/org.jleechanorg.ezgha-token-refresh.plist.template`,
alongside the repo's other launchd job templates, and is picked up automatically
by the shared installer:

```bash
mkdir -p ~/.local/state/ezgha
./launchd/install-launchagents.sh install
```

That copies `scripts/*.sh` (+ `mint_gh_app_token.py`) to the stable
`~/.local/libexec/ezgha/` install dir, substitutes `@SCRIPTS_DIR@`/`@HOME@`,
and loads every `launchd/*.plist.template` in the directory (use
`./launchd/install-launchagents.sh status` to check, or `remove` to unload
and delete the libexec dir). `RunAtLoad=true` mints a token immediately on
load, then `StartInterval=2700` refreshes it every 45 minutes. Logs go to
`~/.local/state/ezgha/token-refresh.log`.

## Daemon auth behavior

`gh help environment` documents token precedence as `GH_TOKEN`, then
`GITHUB_TOKEN`. `ezgha` sets `GH_TOKEN` from `~/.config/ezgha/gh_token` for every
`gh` child process when the file exists and is non-empty, and removes
`GITHUB_TOKEN` from that child environment so a stale exported value cannot
interfere with the app token path. If the file exists but cannot be read, that
`gh` call fails closed instead of silently falling back to shared credentials.

Do not configure the daemon's systemd or launchd environment with an invalid
`GITHUB_TOKEN`. If the app token file is missing or empty, `gh` will fall back to
its normal environment and keyring behavior.
