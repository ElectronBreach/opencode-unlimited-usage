# opencode-unlimited — macOS

The root of this repository is Linux + systemd. macOS has no systemd and no
`unshare -rm`, so those scripts cannot run here as-is. This directory is the
macOS implementation: **launchd**, one rotator, one shared lock, and rotation
that never stops.

```bash
git clone https://github.com/ElectronBreach/opencode-unlimited-usage
cd opencode-unlimited-usage
make mac          # or: bash mac/install-mac.sh
```

Requirements: **Cloudflare WARP.app**, `warp-cli`, `python3`, and Xcode command
line tools (`xcode-select --install`) for the HUD.

Uninstall: `make mac-uninstall`.

---

## What gets installed

| Part | Where | Job |
|---|---|---|
| `ai.ocul.guard` | `~/Library/LaunchAgents` | the rotator (`ocul.py guard`) |
| `com.opencode-unlimited.keeper` | `/Library/LaunchDaemons` | keeps the tunnel up (`warp-keeper.sh`, root) |
| `com.opencode-unlimited.overlay` | `~/Library/LaunchAgents` | the HUD (`OpencodeOverlay.app`) |
| `ocul.py` | `~/.local/share/ocu-lane/` | rotation engine |
| `ouctl` | `~/.local/bin/` | control CLI |
| scripts | `~/.local/share/opencode-unlimited/scripts/` | `zen-hop`, `status`, `doctor`, keeper, mux |

The HUD is **built from source** at install time (`overlay/main.swift` +
`overlay/overlay.html`, via `swiftc`) — there is no prebuilt binary in the repo.

---

## What "unlimited rotation" means

opencode's free tier is keyed on what the server sees: the **egress /64** that
Cloudflare WARP NATs your traffic to (a `2a09:bac…` block), not your public v4
and not the local `utun` address (`2606:4700:110:…`). A new WARP registration
gets a new egress /64. So unlimited rotation = rotate the registration on every
wall, forever.

Three things used to stop that:

| Old behaviour | Why it broke | Now |
|---|---|---|
| 8 rotations/hour cap | a long session hit the cap and rotation "stopped working" | **no cap** — only a 6 s de-dupe |
| 45 s cooldown refusal | back-to-back walls were dropped | **6 s** debounce, never a quota |
| give-up on a saturated burn list | every block comes back burned, guard wedges | oldest entries recycled; retries continue |

Measured on this Mac after the fix: **8 consecutive rotations, 8 unique /64s,
0 failures, 236 s.** No throttling, no refusal.

---

## The macOS-specific bugs this fixes

### 1. Two or three launchd agents driving `warp-cli` at once

The classic broken install has `ai.ocul.guard`, `com.ouc.guard`,
`com.ouc.keeper` and a root `warp-keeper.sh` all on independent timers. They
delete the same registration under each other, one lands the tunnel down
mid-surgery, and the WARP API starts answering
`Failed to communicate with the WARP API`. Symptom: rotation works sometimes,
then not for hours, and your real IP leaks in the gap.

`ouctl consolidate` (run by the installer) leaves exactly one rotator, one
keeper, one HUD. `ouctl doctor` reports any duplicate that reappears.

All rotators now also take **one shared flock**:
`~/Library/Application Support/opencode-unlimited/rotate.global.lock`
plus ocul's own lock and the mkdir lock the shell stack uses.

### 2. The Zero Trust enrollment page

The WARP window is a separate front-end from the root daemon. If it is open
while the registration is deleted it paints *"Something went wrong. Please try
again later."* / *"Enroll your device"*, and keeps it after the tunnel is
healthy. The rotator now **quits the GUI before the surgery and relaunches it
after**.

### 3. The dead daemon

`Unable to connect to the CloudflareWARP daemon: No such file or directory
(os error 2)` — the socket vanishes while WARP.app updates. The rotator proves
the daemon is alive (`warp-cli status`) and relaunches the app until the socket
returns, **before** it touches anything. Both engines do this (`ocul.py` and the
`ouc` fallback).

### 4. A refusal disguised as a check

`proxy-on` used to print
`warp tunnel is down — refusing to open a lane that cannot route` when a launch
raced a rotation. It now repairs the tunnel first and only fails if repair
fails.

### 5. The guard fighting the rotator

The tunnel is *supposed* to be down for a few seconds mid-rotation. The guard
used to see that gap and "repair" it, logging `tunnel down — reconnect` every
hop. It now probes the shared lock first: while any rotator holds it,
`heal_tunnel()` stands down. No more fake outages in `guard.log`.

### 6. The stale lane kill switch

`ocul proxy-off` writes `~/.local/state/ocu-lane/proxy.off`; while that file
exists the guard will not spawn the lane — one `proxy-off` silently disables
self-healing forever. The installer removes a stale marker.

### 7. The HUD's hop button running the wrong engine

The overlay's rotate button runs `zen-hop.sh`. That script used to `exec ouc hop`
**first**, so every click ran the engine with no daemon revival and failed with
`Unable to connect to the CloudflareWARP daemon` — the error you saw in the
overlay console. Order is now:

1. `ocul hop` — canonical (daemon revival, GUI parking, shared lock, unlimited)
2. `ouc hop` — fallback, also hardened
3. the local shell implementation

`status.sh` and `doctor.sh` accept `ai.ocul.guard` and the root keeper daemon as
healthy, so the HUD chips stop reporting the canonical stack as down.

### 8. Disabled labels after an uninstall

`launchctl disable` survives a reinstall, and `bootstrap` against a disabled
label fails with `Input/output error`. The installer re-enables before loading.

---

## When is a rotation accepted?

Only when all three hold:

- the WARP daemon is alive,
- the new **egress** /64 differs from the block we left,
- it is not on the burned blacklist.

Same or burned → rotate again (up to 14 tries per wall, 10 min budget,
escalating backoff on API errors). If the whole pool comes back burned, the
oldest blacklist entries are recycled — buckets reset roughly daily.

---

## Commands

```
ouctl doctor        health check, shows duplicate rotators
ouctl hop           rotate the /64 now (unlimited)
ouctl fix           consolidate + revive daemon + heal tunnel
ouctl consolidate   boot out duplicate agents, keep one rotator
ouctl status        quick state
ocul doctor         raw rotator diagnostics
```

---

## Layout

```
mac/
├── install-mac.sh      installer (clone → working stack)
├── uninstall-mac.sh
├── ocul.py             rotation engine + guard + lane
├── ouctl               control CLI
├── scripts/            zen-hop, status, doctor, keeper, mux, lane
├── overlay/            HUD source — built with swiftc at install
│   ├── main.swift
│   ├── overlay.html
│   └── build.sh
└── plists/             launchd templates (__HOME__ substituted)
```

Templates, not fixed plists: nothing is hardcoded to one username, so the
installer works on any Mac.
