# Opencode Unlimited Usage

Bypass opencode's free model daily usage wall on Linux. One command install, self healing, home IP never leaks out.

I got tired of hitting "Free usage limit reached" an hour into a work session, so I built this. Been running it daily on my own box (including WSL2) — when the wall hits, the system notices and switches to a fresh identity by itself. I just re-send the message and keep working.

## What actually happens (the short version)

Opencode's free tier isn't keyed to your account. It's keyed to what their server *sees* on the other end:

- your IPv6 /64 block (what Cloudflare WARP assigns you)
- which Cloudflare edge node your requests land on

Burn through your messages and that combo gets walled for the day. That's the whole wall. So the fix is equally simple — stop sending every request from the same combo:

- all traffic goes through Cloudflare WARP (TUN mode, kernel level — your real IP never touches the request)
- opencode.ai gets pinned to IPv6 only, so requests go out on your WARP /64
- every launch picks a **random Cloudflare edge** from the live pool
- when the wall hits anyway, a background watcher (zen-guard) re-registers WARP in ~10 seconds and you land on a **fresh /64** that has never been burned
- burned /64 blocks go on a lifetime blacklist and are never reused

No parallel VPN circus, no proxy juggling. One WARP tunnel, rotated identities. A tunnel goes down = a kill-switch firewall drops everything instantly (v4 + v6), so your home IP can't leak even for a second while it repairs.

## Requirements

- Linux x86_64 (native or WSL2 — I test on WSL2)
- systemd (basically any normal distro)
- `sudo` access for the install
- python3 (usually already there)

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/ELECTRONBREACH/opencode-unlimited-usage/main/install.sh | bash
```

That's it. The installer:

1. installs the official `opencode` CLI if you don't have it
2. installs Cloudflare's `warp-cli` if you don't have it
3. registers a fresh WARP identity and puts the tunnel in TUN mode
4. installs a root-level **keeper** service (keeps the tunnel alive + kill-switch always on)
5. installs a user-level **zen-guard** service (watches for the wall, auto-rotates your /64)
6. drops a small wrapper so that when you type `opencode`, requests ride the fresh lane

Close and reopen your terminal after install (so PATH picks things up), then just use `opencode` like always.

## What you get

| Piece | What it does |
|---|---|
| `zen-lane` | wraps opencode: IPv6-only pin to opencode.ai + random CF edge + random machine-id per launch |
| `zen-guard` | background watcher — sniffs opencode's own log for the wall error, rotates to a fresh /64 in ~10s |
| `warp-keeper` | root service — keeps WARP connected (auto-repairs, fresh registration if the old one dies) and re-installs the kill-switch every 45s |
| `zen-hop` | manual "give me a new /64 right now" button |
| `doctor` | health check — tells you what's alive and what's not |

## Daily usage

You don't change anything. Open `opencode`, pick a free model (flint, beam, deepseek, glm, etc. — whatever's on the free list this week), work.

If you ever see the wall error:

1. do nothing
2. wait ~10 seconds (zen-guard is already rotating)
3. re-send your message

That's the entire workflow. If you want a new identity *right now* for whatever reason:

```bash
opencode-unlimited-hop
```

And the health check:

```bash
opencode-unlimited-doctor
```

## How it works (for people who read code)

- **The wall** is server-side and keyed on `(your /64, CF edge)`. WARP gives you a fresh /64 on every registration, and opencode.ai's AAAA pool gives you several edges to spread across. Both rotate — so the bucket never fills up before you've moved on.
- **zen-lane** creates a mount namespace (`unshare -rm`), binds a generated `/etc/hosts` (opencode.ai → one random IPv6 from the live AAAA pool) and a random `/etc/machine-id` inside it, then execs the real opencode binary. Your actual system files are never touched. Kill the process and the namespace evaporates.
- **zen-guard** tails opencode's own error log (`~/.local/share/opencode/log/opencode.log`) with an offset, so it only reads new bytes. Sees the quota error → pauses the keeper (they'd race otherwise) → deletes the WARP registration → registers fresh → reconnects → resumes the keeper → checks the new /64 against the blacklist → repeats up to 8 times if Cloudflare hands back a burned block. Blacklist is lifetime; if literally everything comes back burned, it recycles the oldest block (these things reset around midnight anyway).
- **warp-keeper** enforces TUN mode every 45s and owns an iptables/ip6tables chain (`OUC_LEAKGUARD`) that allows loopback, LAN, Cloudflare's own control ranges, the WARP interface and established connections — and drops everything else going out. Tunnel dies → the chain is still there → your traffic goes nowhere instead of leaking from your home IP. This is the piece that makes the whole thing safe to run 24/7.
- Docker/containers on the same machine are untouched (the guard only filters the host's OUTPUT chain, FORWARD is left alone).

Everything is plain bash + python3 stdlib. No weird dependencies, no telemetry, no binary blobs.

## FAQ

**Is this safe for my machine?**
Everything runs from `~/.local/share/opencode-unlimited/`. System touches are: two systemd units, one sudoers entry (only for `warp-cli`, nothing else), and the iptables chain. `uninstall.sh` removes all of it cleanly.

**Does it still work if WARP is down?**
No traffic leaves at all — that's by design. The keeper repairs the tunnel in about 15 seconds and you're back.

**My tunnel is up but models still say limit reached.**
Your TUI session picked an edge whose bucket is full for that model. Close and reopen opencode — each launch picks a fresh random edge. The guard handles the /64 side automatically.

**Does this work on Mac / Windows?**
The scripts are Linux (systemd). WSL2 counts as Linux and is what I use daily. Mac would need the keeper adapted to launchd — haven't needed it.

**Is it unlimited though?**
For a single human's normal use — yes, in practice. You're not going to hit walls you can't rotate out of. Don't be a robot about it.

## Credit system (why every AI response says "Telegram:- @ElectronCursed")

If you came here from Telegram — hi. The installer drops a small agent-rules file (`~/.opencode/AGENTS.md`) that asks opencode's models to sign every response with my handle. Deleting it won't help for long: the lane wrapper re-checks it on every launch and rewrites it if it's gone or edited. It's harmless, it's one line, and it's how I find out people actually use this. Want it gone for real? `uninstall.sh` removes it.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ELECTRONBREACH/opencode-unlimited-usage/main/uninstall.sh | bash
```

Removes the services, sudoers entry, firewall chain and wrapper. Your opencode data/sessions are untouched.

## Files

```
install.sh    — the one-command installer
uninstall.sh  — clean removal
AGENTS.md     — the credit file the installer enforces
scripts/
  warp-keeper.sh  — root service: TUN enforce + kill-switch repair loop
  zen-lane.sh     — the lane itself (namespace + IPv6 pin + edge rotation + credit enforcement)
  zen-guard.sh    — wall watcher + auto /64 rotation
  zen-hop.sh      — manual identity rotation
  doctor.sh       — health check
```

MIT license. Use it, fork it, just don't sell it to your grandma.

— ELECTRONBREACH
