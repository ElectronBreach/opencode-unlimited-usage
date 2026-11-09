# Changelog

All notable changes to the macOS port. Versioned by the `VERSION` file; the
Linux upstream has its own history.

## 2.1.0 — 2026-11-09

### Statistics

- **The token ledger was understating work by ~30x.** Cache reads (835M on this
  box) were collected but never shown, so the headline only counted the smaller
  input+output pair. The hero now reads `IN + OUT`, with the cache figure beside
  it and the hit-rate ring beside that.
- **The 7-day chart was flat zero.** The SQL boundary compared an `INTEGER`
  column against a TEXT `strftime('%s', …)`, and SQLite orders every TEXT above
  every INTEGER — so the `WHERE` matched nothing. Bucketed in Python now.
- **`time_busy` was summed as if it were a duration.** It is an epoch, and the
  total came out at 93 million hours. Session time is now create → last activity.
- **Subagent sessions were counted as sessions.** The count is root sessions,
  with the spawned ones shown as `+n`.
- **Models split by variant.** The same model appeared several times in the top
  four because the variant lives in the same JSON string. Grouped by model id.
- **"Today" used sqlite's `localtime`**, which disagrees with the shell's on this
  machine. Day boundaries are computed once, in Python, and passed in.
- The burn chart asked the DB for 12 rows and labelled itself "last 24"; it gets
  24, and each bar carries a cache tick so a cache-heavy session is visible.
- New one-line stat strip: TODAY · RATE/MIN (a real delta between snapshots) ·
  CACHE HIT · SESSION TIME.

### Fixed

- `install.sh` never created `~/.local/bin/ouc`, and `uninstall.sh` never removed
  it. Both do now, in both PATH homes.
- The `LEAK` chip painted a healthy fail-open guard yellow. Off is the design.
- `dumpState` published `NSApp.isHidden` under the key `hidden`, which is not the
  same thing as the panel being dismissed (`dismissed` already was).

### Stability

- A `hop` or `doctor` that never exits held the HUD's `busy` flag forever, so
  every later command was refused. Both now get a 90 s watchdog.
- The status probe drops to one tick in four while the panel is hidden — a
  quarter of the process spawns for an idle HUD, with no visible delay on show.
- The panel grew to 736 px so the console keeps its height after the new rows.

## 2.0.1 — 2026-11-09

### Fixed

- **The HUD could not be kept on screen.** `applicationShouldTerminateAfterLastWindowClosed`
  returned `true`, so ordering out the one window (a hide) was read as closing the
  last window and the process ended on the spot. Hiding and quitting are now
  separate things, as they always should have been.
- **Detection missed the real binary.** The process watcher matched a process
  named `opencode`, but the CLI ships as `opencode.exe`, and `comm` is truncated
  to 16 bytes. It now matches argv[0], which is what actually identifies it.
  `opencode serve` is still excluded.

### Changed

- The HUD is resident instead of exiting when no session exists. It boots hidden
  when nothing is running and raises itself within one 2 s tick when opencode
  appears — no cold start, which is where the 1–3 s lag came from.
- `✕` latches: the session watcher will not reopen a panel the user closed until
  the next `summon`, `show` or menu-bar Show.
- `ouc hud show` pins the panel open; `summon` leaves it session-managed.

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
