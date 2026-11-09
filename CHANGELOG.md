# Changelog

All notable changes to the macOS port. Versioned by the `VERSION` file; the
Linux upstream has its own history.

## 2.0.0 — 2026-11-09

First versioned release of the macOS port. Everything below is macOS-specific
work on top of the upstream scripts: `launchd` instead of `systemd`, `pf`
instead of `iptables`, and an AppKit HUD instead of nothing.

### Added

- **The HUD** (`scripts/overlay/`) — a borderless `NSPanel` + `WKWebView`
  showing live token data, identity, subsystem chips, session burn and a
  console for command output. Every control runs a real script.
- **OpenCode Console key pool** (`scripts/api-keys.sh`) — add, remove, rotate
  forward and back, probe, prune, and a 50-key cap. The pool lives in the
  `credential` table; exactly one row is `active`.
- **`ouc`** — one entry point: `status`, `doctor`, `audit`, `keys`, `hud`,
  `hop`, `logs`, `paths`, `version`.
- **Release packaging** — `make release` produces a versioned tarball and
  `SHA256SUMS`; `install.sh` remains a single self-contained file.
- Docs: `docs/ARCHITECTURE.md`, `docs/HUD.md`, `docs/TROUBLESHOOTING.md`.

### Stability

- `warp-keeper.sh`: status-agnostic probes on literal/Cloudflare targets, so a
  429 from a public IP service can no longer be read as "egress dead" and
  bounce the tunnel under an in-flight model fetch.
- `warp-keeper.sh`: never bounces while opencode touched a session in the last
  90 s.
- `warp-keeper.sh`: watches `getaddrinfo`, not just `dig`, and repairs a wedged
  resolver in place — the exact failure that breaks browsers.
- `warp-keeper.sh`: enforces `TunnelOnly` and proves the route before trusting
  it after a mode change.
- `zen-guard.sh`: resets the provider on `ModelUnavailableError`; `rotate.lock`
  serialises the guard against a manual hop.
- HUD: survives SIGKILL under launchd, one instance, `evictOlderInstances`.
- HUD: reload backoff (1→30 s) instead of a 1/s retry storm.
- HUD: recovers a killed web content process instead of showing a white panel.
- HUD: launch-loop guard — 6 launches in 2 min → 30 s backoff.
- HUD: refreshes the WARP GUI when it loses its window, checked every 4 s.

### Behaviour changes

- The HUD is no longer a login item. It is summoned by the lane with opencode
  and steps back a minute after the last session exits. `ouc hud show` pins it.
- `✕` hides the panel instead of folding it to a bubble that stays on top.
- `ouc hud quit` really quits: it boots the agent out so `KeepAlive` cannot
  resurrect it.
- `doctor.sh` reports the WARP UI separately from the WARP tunnel.
- `doctor.sh` separates "no packets" from "name lookup wedged".

## Earlier

Unversioned work on the `macos` branch: the port itself, the lane, the keeper,
the guard, the installer/uninstaller, the sudoers contract and the DNS
baseline. See `git log`.
