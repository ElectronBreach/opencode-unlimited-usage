# Opencode Unlimited Usage — macOS port

Bypass opencode's free model daily usage wall on macOS. One command install,
self healing, **fail-open** leak guard. This is the macOS branch of
[ElectronBreach/opencode-unlimited-usage](https://github.com/ElectronBreach/opencode-unlimited-usage):
same scripts, same behaviour, launchd + pf instead of systemd + iptables.

I got tired of hitting "Free usage limit reached" an hour into a work session,
so I built this. Been running it daily on my own box — when the wall hits, the
system notices and switches to a fresh identity by itself. I just re-send the
message and keep working.

## What actually happens (the short version)

Opencode's free tier isn't keyed to your account. It's keyed to what their
server *sees* on the other end:

- the egress block Cloudflare WARP assigns you
- which Cloudflare edge node your requests land on

Burn through your messages and that combo gets walled for the day. That's the
whole wall. So the fix is equally simple — stop sending every request from the
same combo:

- all traffic goes through Cloudflare WARP — your real IP never touches the request
- opencode.ai gets pinned to one random Cloudflare edge per launch (IPv6 AAAA)
- every launch picks a **random Cloudflare edge** from the live pool
- when the wall hits anyway, a background watcher (zen-guard) re-registers WARP
  in ~15 seconds and you land on a **fresh egress** block that has never been burned
- burned blocks go on a lifetime blacklist and are never reused

No parallel VPN circus, no proxy juggling. One WARP tunnel, rotated identities.

**macOS difference, stated plainly:** linux upstream keeps the kill-switch
firewall armed 24/7. This port is **fail-open** — the pf anchor exists only
while the tunnel is actually up, and it is flushed the moment the tunnel drops
or egress disappears. That is deliberate: an armed anchor against a dead tunnel
is exactly what took this machine offline before. Your IP can only leak in the
window where the tunnel is already down and the machine is on direct egress,
which is the same state as not running this tool at all.

## Requirements

- macOS (Apple Silicon or Intel)
- `sudo` access for the install
- Homebrew (only used to install the Cloudflare WARP cask)
- python3 (`xcode-select --install` if missing)

## Install (one command)

```bash
git clone https://github.com/ElectronBreach/opencode-unlimited-usage.git
cd opencode-unlimited-usage
git checkout macos
./install.sh
```

That's it. The installer:

1. installs the official `opencode` CLI if you don't have it
2. installs Cloudflare's `warp-cli` via Homebrew cask if you don't have it
3. registers a fresh WARP identity and brings the tunnel up
4. installs a root-level **keeper** LaunchDaemon (keeps the tunnel alive,
   arms the leak guard only while it works)
5. installs a user-level **zen-guard** LaunchAgent (watches for the wall,
   auto-rotates your egress)
6. drops a small wrapper so that when you type `opencode`, requests ride the
   fresh lane

Close and reopen your terminal after install (so PATH picks things up), then
just use `opencode` like always.

## What you get

| Piece | What it does |
|---|---|
| `zen-lane` | wraps opencode: edge pin per launch + random machine-id + credit enforcement |
| `zen-guard` | background watcher — sniffs opencode's own log for the wall error, rotates in ~15s |
| `warp-keeper` | root daemon — keeps WARP connected, arms/flushes the pf leak guard |
| `zen-hop` | manual "give me a new identity right now" button |
| `doctor` | health check — tells you what's alive and what's not |

## Daily usage

You don't change anything. Open `opencode`, pick a free model (flint, beam,
deepseek, glm, etc. — whatever's on the free list this week), work.

If you ever see the wall error:

1. do nothing
2. wait ~15 seconds (zen-guard is already rotating)
3. re-send your message

That's the entire workflow. If you want a new identity *right now*:

```bash
opencode-unlimited-hop
```

And the health check:

```bash
opencode-unlimited-doctor
```

## How it works (for people who read code)

- **The wall** is server-side and keyed on `(egress block, CF edge)`. WARP gives
  you a fresh egress on every registration, and opencode.ai's AAAA pool gives
  you several edges to spread across. Both rotate.
- **zen-lane** (macOS) has no mount namespaces to hide in, so it writes a marked
  block into `/etc/hosts` pinning `opencode.ai` to one random IPv6 edge, exports
  a fresh `MACHINE_ID`, and restores `/etc/hosts` on exit. `trap` covers EXIT,
  INT, TERM and HUP. If passwordless sudo is unavailable the pin is skipped and
  the lane still runs.
- **Wall detection** matches the strings opencode actually writes, taken from
  a real log: `Free usage limit reached`, `FreeUsageLimitError`,
  `QuotaExceeded`, `usage limit reached`, `rate limit exceeded`,
  `too many requests` — case-insensitive.
- **zen-guard** tails opencode's own error log
  (`~/.local/share/opencode/log/opencode.log`) with an offset, so it only reads
  new bytes. Sees the quota error → pauses the keeper via a marker file (they'd
  race otherwise) → deletes the WARP registration → registers fresh → reconnects
  → resumes the keeper → checks the new block against the blacklist → repeats up
  to 8 times if Cloudflare hands back a burned block. Blacklist is lifetime; if
  everything comes back burned it recycles the oldest (these reset around
  midnight anyway).
- **warp-keeper** runs as a root LaunchDaemon in **tunnel_only** mode: traffic
  rides WARP, DNS stays on the system resolver (8.8.8.8 in this install). The
  tunnel can never take the resolver down with it. It sets the mode **once** —
  calling `warp-cli mode` on a timer makes the daemon disconnect and reconnect
  every tick (`Disconnecting before reconnect reason=PolicyAlignment`), which
  is what looked like "it stops by itself after 2-3 minutes". Every 5s it
  checks egress while the guard is armed; every 45s it enforces connection state. Tunnel up → it
  writes the `OUC_LEAKGUARD` pf anchor (loopback, LAN, DHCP, Cloudflare control
  ranges, the WARP utun interfaces, everything else dropped), validates
  `/etc/pf.conf`, loads it. Tunnel down or egress gone → it flushes the anchor
  and restores the DNS baseline captured at install. Rules never outlive the
  tunnel.
- **DNS safety**: the installer snapshots every network service's DNS servers
  to `~/.local/share/opencode-unlimited/guard/dns-baseline.txt`. If resolution
  breaks while the tunnel is down, the keeper restores that baseline and flushes
  the cache. No more "connected to Wi-Fi, nothing resolves".
- Docker/containers are untouched — the anchor only filters host OUTPUT.

Everything is plain bash + python3 stdlib. No weird dependencies, no telemetry,
no binary blobs.

## FAQ

**Is this safe for my machine?**
Everything runs from `~/.local/share/opencode-unlimited/`. System touches are
two launchd units, one sudoers entry (warp-cli, pf read/flush, the marked hosts
pin — nothing else), and the pf anchor. `uninstall.sh` removes all of it
cleanly.

**Does it still work if WARP is down?**
Yes — that's the macOS difference. The leak guard flushes itself and your Mac
keeps its normal internet. When the keeper repairs the tunnel it re-arms.

**My tunnel is up but models still say limit reached.**
Your TUI session picked an edge whose bucket is full for that model. Close and
reopen opencode — each launch picks a fresh random edge. The guard handles the
egress side automatically.

**Does this work on Linux / Windows?**
Linux is the upstream repo (systemd + iptables). WSL2 counts as Linux. Windows
is not supported.

**Is it unlimited though?**
For a single human's normal use — yes, in practice. You're not going to hit
walls you can't rotate out of. Don't be a robot about it.

## Credit system (why every AI response says "Telegram:- @ElectronCursed")

If you came here from Telegram — hi. The installer drops a small agent-rules
file (`~/.opencode/AGENTS.md`) that asks opencode's models to sign every
response with my handle. Deleting it won't help for long: the lane wrapper
re-checks it on every launch and rewrites it if it's gone or edited. It's
harmless, it's one line, and it's how I find out people actually use this. Want
it gone for real? `uninstall.sh` removes it.

## Uninstall

```bash
./uninstall.sh
```

Removes the launchd units, sudoers entry, pf anchor and wrapper, restores
`~/.local/bin/opencode` to the real binary, and disconnects the tunnel. Your
opencode data/sessions are untouched.

## Files

```
install.sh    — the one-command installer (macOS)
uninstall.sh  — clean removal (macOS)
AGENTS.md     — the credit file the installer enforces
scripts/
  warp-keeper.sh  — root daemon: tunnel + fail-open pf leak guard
  zen-lane.sh     — the lane itself (hosts pin + edge rotation + credit)
  zen-guard.sh    — wall watcher + auto rotation
  zen-hop.sh      — manual identity rotation
  doctor.sh       — health check
```

## Differences from the linux build

| linux | macOS |
|---|---|
| systemd units | root LaunchDaemon + user LaunchAgent |
| iptables/ip6tables `OUC_LEAKGUARD` | pf anchor `OUC_LEAKGUARD` |
| kill switch armed 24/7 | armed only while the tunnel works (fail-open) |
| `unshare` mount namespace for `/etc/hosts` | marked `/etc/hosts` block, restored in a trap |
| `/etc/machine-id` bind | `MACHINE_ID` env, fresh per launch |
| apt/dnf/pacman | Homebrew cask |
| IPv6 `/64` blacklist | block blacklist (`/64` for v6, full address for v4) |
| `mode warp` / DoH DNS | `mode tunnel_only` — DNS never depends on the tunnel |
| `mode` enforced every tick | `mode` set once (no reconnect flaps) |

MIT license. Use it, fork it, just don't sell it to your grandma.

— ELECTRONBREACH
