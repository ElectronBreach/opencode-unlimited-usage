# opencode-unlimited — macOS

The root of this repo is Linux + systemd. macOS has neither systemd nor
`unshare -rm`, so the Linux scripts cannot run here as-is. This directory is the
macOS implementation: **launchd**, one rotator, one shared lock, and rotation
that never stops.

## Install

```bash
git clone https://github.com/ElectronBreach/opencode-unlimited-usage
cd opencode-unlimited-usage/mac
./install-mac.sh
```

Prerequisites: Cloudflare WARP.app installed, `warp-cli` on PATH, `python3`.

## What "unlimited rotation" means here

opencode's free tier is keyed on what the server sees: the **egress /64** that
Cloudflare WARP NATs your traffic to (a `2a09:bac…` block), not your public v4
and not the local `utun` address. A new WARP registration gets a new egress /64.
So unlimited rotation = rotate the registration on every wall, forever.

Three things used to stop that, and this implementation removes all three:

| Old behaviour | Why it broke | Fixed |
|---|---|---|
| 8 rotations/hour cap | a long session hit the cap and rotation "stopped working" | no cap — only a 6 s de-dupe so one wall = one hop |
| 45 s cooldown refusal | back-to-back walls were dropped | 6 s debounce, never a quota |
| give-up on a saturated burn list | every block comes back burned, guard wedges | oldest blacklist entries recycled; retries continue |

## The bugs this fixes on macOS specifically

**Two or three launchd agents driving `warp-cli` at once.** The classic broken
install has `ai.ocul.guard` (rotator), `com.ouc.guard` (python guard),
`com.ouc.keeper` (python keeper) and a root `warp-keeper.sh` all on independent
timers. They delete the same registration under each other, one lands the tunnel
down mid-surgery, and the WARP API starts answering
`Failed to communicate with the WARP API`. Symptom: rotation works sometimes and
then not for hours, and your real IP leaks in the gap (`103.180.203.x` in the
logs).

Fixed by `ouctl consolidate`: exactly one rotator (`ai.ocul.guard`), one keeper
(`com.opencode-unlimited.keeper`), one HUD (`com.opencode-unlimited.overlay`).
`ouctl doctor` reports any duplicate that reappears.

**The Zero Trust enrollment page.** The WARP window is a separate front-end from
the root daemon. If it is open while the registration is deleted it paints
*"Something went wrong. Please try again later."* / *"Enroll your device"* and
keeps it after the tunnel is healthy. The rotator now **quits the GUI before the
surgery and relaunches it after**.

**The dead daemon.** `Unable to connect to the CloudflareWARP daemon: No such
file or directory (os error 2)` — the socket file vanishes while WARP.app
updates. The rotator proves the daemon is alive (`warp-cli status`) and
relaunches the app until the socket returns, before it touches anything.

**A refusal disguised as a check.** `proxy-on` used to print
`warp tunnel is down — refusing to open a lane that cannot route` when a launch
raced a rotation. It now repairs the tunnel first and only fails if repair
fails.

## The HUD's hop button

The overlay's rotate button runs `zen-hop.sh` from
`~/.local/share/opencode-unlimited/scripts/`. That script used to `exec ouc hop`
**first**, so every click ran the engine with no daemon revival and failed with
`Unable to connect to the CloudflareWARP daemon`. The order is now:

1. `ocul hop` (canonical — daemon revival, GUI parking, shared lock, unlimited)
2. `ouc hop` (fallback, also hardened in `opencode-unlimited-mac`)
3. the local shell implementation

`zen-hop.sh` in this directory is the patched copy. `status.sh` and `doctor.sh`
accept `ai.ocul.guard` and the root keeper daemon as the healthy agents, so the
HUD chips and the doctor sheet stop reporting the canonical stack as down.

## The guard stops fighting the rotator

The tunnel is *supposed* to be down for a few seconds mid-rotation. The guard
used to see that gap and "repair" it — reconnecting under the rotator mid-surgery
and logging `tunnel down — reconnect` every time. It now checks the same global
lock first: while any rotator holds it, `heal_tunnel()` stands down and returns
healthy. No more fake outages in `guard.log`, no more reconnects racing a
registration swap.

## The stale lane kill switch

`cmd_proxy_off` writes `~/.local/state/ocu-lane/proxy.off`; while that file
exists the guard will not spawn the lane, so a single `ocul proxy-off` silently
disables self-healing forever. If the lane looks permanently down, check for it:

```bash
ls ~/.local/state/ocu-lane/proxy.off && rm -f ~/.local/state/ocu-lane/proxy.off
```

## How rotation is serialised

Every rotator on the machine takes the same three locks, in this order:

1. `~/Library/Application Support/opencode-unlimited/rotate.global.lock` — flock shared by all stacks
2. `~/.local/state/ocu-lane/rotate.lock` — ocul's own
3. `~/.local/share/opencode-unlimited/guard/rotate.lock` — mkdir taken by `zen-hop.sh`

Plus a keeper-pause marker so the keeper never re-registers mid-surgery.

## A rotation is accepted only when

- the daemon is alive,
- the new **egress** /64 differs from the block we left,
- it is not on the burned blacklist.

If Cloudflare hands back the same or a burned block, it rotates again
(up to 14 tries per wall, 10 min budget, escalating backoff on API errors).
If the whole pool comes back burned, the oldest blacklist entries are recycled —
buckets reset roughly daily. There is no global count that ever stops it.

## Commands

```
ouctl doctor        health check, shows duplicate rotators
ouctl hop           rotate the /64 now
ouctl fix           consolidate + revive daemon + heal tunnel
ouctl consolidate   boot out duplicate agents, keep one rotator
ouctl status        quick state
```

## Uninstall

```bash
ouctl uninstall
```

Removes the launchd agent and launcher; `ocul.py` stays in place.
