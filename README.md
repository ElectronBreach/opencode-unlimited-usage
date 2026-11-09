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
| `api-keys` | OpenCode Console key pool — add, rotate, probe, prune, 50-key cap |
| `proxy-pool` | local rotating proxy: add webshare-style upstreams, test, rotate, system-wide |
| `model-levers` | the 51 free models on the `opencode` provider — list, switch, burn |
| `overlay` | always-on-top HUD: hop + doctor + live token ledger + key pool + PROXY sheet |
| `ouc` | one entry point for every one of the above |

## Daily usage

You don't change anything. Open `opencode`, pick a free model (flint, beam,
deepseek, glm, etc. — whatever's on the free list this week), work.

If you ever see the wall error:

1. do nothing
2. wait ~15 seconds (zen-guard is already rotating)
3. re-send your message

That's the entire workflow. Everything is reachable through one command:

```bash
ouc                   # live status: tunnel, egress, tokens, keys
ouc doctor            # health check, one line per subsystem
ouc audit             # feature audit against the linux upstream
ouc hop               # new identity right now
ouc keys list         # the key pool
ouc keys rotate next  # switch active key
ouc logs keeper       # tail a log (keeper | guard | overlay | lane)
ouc paths             # every file this install owns
```

`opencode-unlimited-hop` and `opencode-unlimited-doctor` still exist as
one-word aliases. `ouc help` prints the rest.

## The overlay HUD

A small always-on-top window that opens **by itself** every time `opencode`
starts — any session, any project. It is not decoration: it runs the same
scripts you would run by hand and reads the same database opencode writes.

- **tokens** — input + output with the cache figure, hit rate, cost and session
  count, refreshed every 2 s straight out of
  `~/.local/share/opencode/opencode.db` (read-only, never cached)
- **today · rate/min · cache hit · session time** — the four numbers that say
  what this actually cost to run
- **tabs** — IDENTITY · KEYS · STATS share one fixed pane, and the console sits
  below them with the leftover height, so it is never squeezed out
- **identity** — egress address, the server-seen `/64` (the actual quota key),
  device id, rotation count
- **health** — warp / DNS / keeper / guard / credit / leak-guard, one dot each
- **API keys** — the OpenCode Console key pool: add, prev/next, check, clean, delete
- **HOP** and **DOCTOR** — the two commands, running live, output in the console
- **PROXY** — a sheet over the panel with two more levers: a rotating proxy mux
  (add upstreams, test them, rotate live, or route the whole machine through
  it) and the free-model list (51 zero-cost models, switch with one tap). The
  panel does not grow: the sheet covers it, the console keeps its height
- **session burn** — the last 24 sessions that spent anything, ranked
- **⇄** docks it to the other screen edge, **−** collapses it, **✕** hides it

Collapsed it becomes a single circular badge that keeps floating on top:
token count, cache-hit ring, status dot. Click it to expand, double-click to
fire a rotation. Drag it anywhere — it snaps to the screen edges.

```bash
ouc hud show          # pin it open
ouc hud summon        # what a session launch does
ouc hud hide          # put it away
ouc hud quit          # stop it — really stop it, KeepAlive cannot revive it
ouc hud warp          # open the Cloudflare WARP window
```

Set `OUC_OVERLAY=0` before launching opencode if you want it to stay shut.

**It is a separate floating window, not a pane inside the terminal.** It sits
above your terminal at the right edge of the screen (or wherever you drag it),
non-activating, so typing in the terminal never loses focus. It follows you
across Spaces and stays on top of a fullscreen terminal.

**It belongs to a session, but the process stays resident.** The lane raises it
when opencode launches; when the last session exits it steps back after a minute.
With nothing running it waits hidden — a few MB, no window — and raises itself
within one 2 s tick the moment `opencode` appears. That is why there is no cold
start: the panel is already built by the time you need it. `ouc hud show` pins it
open; `✕` keeps it closed until you ask again.

**✕ hides the panel, it does not fold it.** The process stays; the ⚡ menu bar
item brings it back, and the next `opencode` launch summons it again. The real
quit is `ouc hud quit`.

Not seeing it?

```bash
ouc hud show                                   # raise it now
cat ~/.local/share/opencode-unlimited/guard/overlay-state.json   # visible / frame
ouc logs overlay | tail -20                    # why it exited
```

If `visible` is `true`, it is on screen — look for a 366×700 panel at the right
edge, or the 78 px circle if it was left collapsed.

Reading tokens is read-only (`mode=ro` against the live WAL database) — the
HUD never writes to opencode's data.

The full control map and the click-coordinate trick used to verify every button
are in [docs/HUD.md](docs/HUD.md).

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

**What is the fastest way out of a wall?**
Switch model. The wall text itself says "or switch models", and there are 51
zero-cost models on the `opencode` provider, each with its own free quota —
`PROXY` chip → `MODELS` page, one tap, no tunnel, no registration, no DNS
window. The chip sits at the right end of the identity row; the menu bar item
`Proxy & Models…` opens the same sheet.
Rotating the `/64` is the expensive lever and comes second. The guard logs
"the wall is not the ip right now" once it has proven the egress is not the
problem, and it never switches a model behind a running session.

**What are the proxies for?**
Optional. The `PROXY` chip (or menu bar → `Proxy & Models…`) runs a local
`CONNECT` mux on `127.0.0.1:8899`. While it is up, `zen-lane.sh` exports
`HTTP(S)_PROXY` so the CLI's traffic — including its long-lived `serve
--service` child — goes through the mux and rotates; the
client points at it once and the mux rotates upstreams behind that fixed
address, so a rotation costs no restart and no DNS window. Paste webshare-style
`host:port:user:pass` lines, hit `TEST` to see which are alive, `ON` to start.
The mux fails closed — a dead pool gets 502, never a direct connection.

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

## One-file install

`install.sh` carries the macOS scripts inside itself. A piped install works
with no checkout and no published branch:

```bash
cat install.sh | bash
```

A local checkout still installs from its own files. The payload is regenerated
with `bash tools/embed.sh` after any script change.

## Audit

```bash
ouc audit                  # feature-by-feature vs the linux build
```

Prints `pass / deviation / fail`. Deviations are the documented macOS
adaptations below, never silent gaps.

## WARP GUI note

The GUI app is not needed — the daemon does the work and the CLI drives it.
If the app opens on "Setting things up…" and hangs, quit it; the keeper
re-bootstraps `com.cloudflare.1dot1dot1dot1.macos.warp.daemon` if the daemon
ever goes missing. The installer also removes it from your login items so the
window does not come back at boot.

## Reliability notes (macOS)

**The guard cannot silently vanish.** `launchctl bootout` is asynchronous, so
the installer waits for the domain to release the label, retries `bootstrap`,
and re-verifies after a settle window. The root keeper also checks every slow
tick that `gui/<uid>/com.opencode-unlimited.guard` is registered and
re-bootstraps it as the install user if it is not.

**A dead lane cannot leave a pin behind.** `/etc/hosts` pins are owned by a
pid file (`guard/lane.pid`). A lane killed with `-9` skips its trap, so the
keeper sweeps any marked block with no live owner on its next fast tick.
Uninstall removes the block too.

**PATH tools resolve in terminals that are already open.** `${BRAND}-hop` and
`${BRAND}-doctor` are linked into both `~/.local/bin` and `~/.opencode/bin`
(the latter is normally first on an opencode shell's PATH).

**Uninstall leaves nothing.** Shim deleted (not rewritten), both sudoers file
names removed, legacy `-mac` paths and dangling symlinks removed, DNS reset to
DHCP when no baseline was recorded.

**The rotation key is the warp /64.** Cloudflare hands a fresh IPv6 /64 on
every registration (`2606:4700:110:xxxx::/64`), and only a v6 request carries
that prefix to the server. The lane therefore pins an IPv6 edge first — v4 is
the fallback for a host with no v6 path, and it is why a v4-only rotation looks
like it only ever sees four addresses.

**Apple Silicon.** Every component is arm64-native or a universal binary. The
cask puts `warp-cli` in `/usr/local/bin`; scripts fall back to
`/opt/homebrew/bin` and then to the bundled
`/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli`.

## Uninstall

```bash
./uninstall.sh
```

Removes the launchd units, sudoers entry, pf anchor and wrapper, restores
`~/.local/bin/opencode` to the real binary, and disconnects the tunnel. Your
opencode data/sessions are untouched.

## Files

```
install.sh        one-command installer; carries the whole payload inside itself
uninstall.sh      clean removal — units, sudoers, pf, DNS baseline, HUD
VERSION           the version this checkout is
Makefile          check / build / test / install / release / clean
CHANGELOG.md      what changed, per release

scripts/
  ouc.sh          the one entry point
  warp-keeper.sh  root daemon: tunnel + fail-open pf leak guard + DNS repair
  zen-lane.sh     the lane itself (hosts pin + edge rotation + credit + session)
  zen-guard.sh    wall watcher + auto rotation
  zen-hop.sh      manual identity rotation
  api-keys.sh     OpenCode Console key pool
  doctor.sh       health check
  audit.sh        feature audit vs the linux build
  parity.sh       numeric parity against the linux build
  status.sh       machine-readable snapshot (JSON) for the HUD
  overlay-ctl.sh  show / summon / hide / quit / warp
  overlay/        the AppKit + WKWebView HUD (main.swift, overlay.html, build.sh)

docs/
  ARCHITECTURE.md     the three processes, the state directory, failure modes
  HUD.md              every control, what it runs, how it was verified
  TROUBLESHOOTING.md  the failure that looks like "my Mac is broken"

tools/
  embed.sh        rebuild or verify the payload inside install.sh
```

## Building a release

```bash
make check      # every script parses + the embedded payload is current
make build      # compile the HUD
make test       # doctor + audit against this machine
make release    # dist/opencode-unlimited-mac-<version>.tar.gz + SHA256SUMS
```

`make release` is deliberately boring: a tarball, a checksum, no signing, no
network. `install.sh` in the tarball is the same self-contained file as the one
in the repo, so a release can be installed with `./install.sh` or
`cat install.sh | bash` exactly like a checkout.

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

This is `VERSION` 2.5.5 — see [CHANGELOG.md](CHANGELOG.md).

— ELECTRONBREACH
