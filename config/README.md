# Fleet config templates

Reference `config.toml` files for the two production ezgha hosts. These are **not**
auto-installed — copy to `~/.config/ezgha/config.toml` after editing limits for your
machine.

```bash
# MacBook (6× ez-mac-runner-b-*)
cp config/config.toml.mac.example ~/.config/ezgha/config.toml

# jeff-ubuntu (16× ez-runner-b-*)
cp config/config.toml.linux.example ~/.config/ezgha/config.toml
```

Then restart the supervisor:

```bash
# macOS
launchctl kickstart -k gui/$(id -u)/org.jleechanorg.ezgha

# Linux
systemctl --user restart ezgha.service
```

## `minimum_isolation` policy

| Host | Value | Why |
|------|-------|-----|
| Mac (Colima) | `container` | Colima runs docker inside a VM, but ezgha's backend isolation level is still `container`. `minimum_isolation = "vm"` causes serve to **fail-closed** when the daemon blips to container-only. |
| Linux (native docker) | `container` | Bare-metal docker on the host kernel; strongest available backend is `container`. Use `vm` only if you have a VM-contained daemon **and** want fail-closed enforcement. |

**Image:** always `ezgha-runner:latest` (built from `Dockerfile.runner`), not the bare upstream `actions-runner` image.
