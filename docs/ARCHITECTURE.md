# Architecture

Three long-lived processes, one database, one panel. Everything else is a
script you run by hand.

```
                 opencode  (the real binary)
                     │  launched through ~/.local/bin/opencode
                     ▼
            scripts/zen-lane.sh        one per terminal session
              · picks a random Cloudflare edge
              · pins opencode.ai to it in /etc/hosts
              · drops guard/sessions/<pid>
              · summons the HUD
                     │
     ┌───────────────┼───────────────────────────────┐
     ▼               ▼                               ▼
keeper (root)   zen-guard (user)                 HUD (user app)
launchd daemon  launchd agent 6 s loop          OpencodeOverlay.app
· WARP tunnel   · watches the session log       · NSPanel + WKWebView
· DNS repair    · notices the wall              · reads guard/status-…
· resolver      · rotates identity              · drives scripts by
  watchdog      · rewrites /etc/hosts             writing guard/overlay-cmd
· fail-open
```

## The pieces

| Path | Runs as | Lifetime | Job |
|---|---|---|---|
| `scripts/warp-keeper.sh` | root, launchd daemon | always | keeps the WARP tunnel carrying traffic, repairs DNS, enforces `TunnelOnly` |
| `scripts/zen-guard.sh` | user, launchd agent | always | watches the opencode log for the usage wall and rotates identity |
| `scripts/zen-identity.sh` | sourced | — | the one definition of identity: what a rotation has to change |
| `scripts/zen-lane.sh` | user, per opencode launch | session | pins the edge, registers the session, raises the HUD |
| `scripts/overlay/main.swift` | user, launchd agent | session | the panel; starts only when a session exists |
| `scripts/status.sh` | user, on demand | — | one JSON snapshot of everything |
| `scripts/api-keys.sh` | user, on demand | — | the OpenCode Console key pool |
| `scripts/doctor.sh` / `audit.sh` | user, on demand | — | health and feature parity |
| `scripts/ouc.sh` | user | — | the one entry point for all of the above |

## State

Everything mutable lives in `~/.local/share/opencode-unlimited/`:

```
guard/
  lane.pid  lane.lock              which lane owns the /etc/hosts pin
  sessions/<pid>                   one file per live opencode session
  rotate.lock                      serialises guard + manual rotation
  overlay-cmd                      command channel: the HUD polls this
  overlay-intent                   "summon|show <ts>" — how a cold start knows why
  overlay-state.json               what the window is actually doing
  overlay-crash.log                one line per surprise
  identities.json                  per-bucket ledger: walls, hops, first/last
  key-probe.json                   10 min cache of console key verdicts
  status-cache.json                12 s cache of the network probes
  keeper.log guard-daemon.log overlay-daemon.log
```

## What a rotation has to change

The quota is keyed on the **egress IPv6 /64** cloudflare hands the server, as
seen from the far side (`2a09:bac*`), not the utun leg on this machine and not
the registration id. `zen-identity.sh` holds that rule once:

- `oui_bucket` probes `cdn-cgi/trace` over v6 (v4 only when the tunnel has no
  v6 path) and returns the /64.
- `oui_is_egress` refuses anything outside cloudflare's egress ranges, which is
  what keeps the tunnel's inside leg and a direct ISP address out of the blacklist.
- `oui_bl_add` / `oui_bl_has` store and match nothing but egress buckets.
- `oui_bl_migrate` repairs a blacklist written before the rule existed.
- `oui_ledger` keeps `guard/identities.json`: per bucket, walls, hops, first
  and last seen. the HUD and `doctor.sh` read it.
- a landing is accepted only when the bucket is new **and** absent from the
  blacklist. a burnt block stays burnt for the better part of a day — `b40:8`
  walled at 01:05 and walled again three minutes after we re-landed on it at
  10:05 — so reuse is a guaranteed wall, not a gamble.
- eight tries that all land on burned blocks mean the pool is saturated right
  now. the guard says so and parks 15 min instead of churning the tunnel.

The console key is a *fallback* lever, not the first move: it is only spent
when the `/64` pool is out of fresh blocks, because rotating the active key
costs nothing (no registration, no tunnel, no dns window) but on this machine
the ip is what has actually cleared every wall. one wall after a key swap is
the verdict, and it is remembered for the run.

The guard and the manual hop both judge success by `oui_bucket` changing. A new
registration id on the same /64 is a no-op, and treating it as a rotation is
what made the tool look broken half the time.

Token numbers come from `~/.local/share/opencode/opencode.db` (`session_v2`),
read-only, every call — never cached. Only network probes are cached, because
they are the expensive part.

## Why the HUD lives with a session

The panel is a companion to opencode, not a login item. `RunAtLoad` starts it,
it finds no session marker and no launch intent, and exits with status 0
(which `KeepAlive.SuccessfulExit=false` does not restart). The lane summons it,
`launchd` supervises it, and when the last session exits it steps back after a
minute. `ouc hud show` pins it for as long as you leave it.

## Rotation, in one paragraph

The wall is keyed to the egress block Cloudflare gives you and the edge node
you land on. The keeper notices the tunnel is up but not carrying traffic; the
guard notices the wall in the log. Either way `zen-hop.sh` re-registers WARP,
gets a new `/64`, blacklists the old one for good, and the lane re-pins
`opencode.ai` to a different edge. `rotate.lock` makes sure the guard and a
manual `ouc hop` never race each other.

## Failure modes that are designed for

| What breaks | What happens |
|---|---|
| WARP disconnects | keeper reconnects with backoff 120→300→600→1200 s |
| Tunnel up, no traffic | keeper bounces it after 9 stalled ticks |
| `getaddrinfo` wedges (browsers break, `dig` still answers) | keeper flushes the cache and HUPs mDNSResponder, at most once per 2 min |
| `warpwithdnsoverhttps` gets set | keeper forces `TunnelOnly` and proves the route before trusting it |
| The HUD is SIGKILLed | launchd restarts it in ~5 s, one instance |
| WARP's GUI loses its window | the HUD notices within 8 s and relaunches only the GUI |
| The web content process is killed | the HUD reloads the page |
| The HUD crash-loops on boot | 6 launches in 2 min → 30 s backoff instead of a spin |
