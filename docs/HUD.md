# The HUD

`OpencodeOverlay.app` — one borderless `NSPanel` running a local HTML page in a
`WKWebView`. No network, no dependencies, no Electron.

## When it is on screen

- the lane summons it on every opencode launch (`ouc hud summon`)
- `ouc hud show` pins it open until you close it
- it hides itself a minute after the last session exits
- `✕` hides it. It is not a quit: the process stays, the menu bar item brings
  it back, and the next opencode launch summons it again
- `−` collapses it to the 78 px bubble (still on screen)
- menu bar item (⚡): Show / Hide / Collapse / Reload / Open WARP / Restart WARP
  UI / Quit

Inside, `✕` shadows the window, `⇄` docks it to the other side of the screen,
and the header is a drag handle.

## What the controls actually do

Every button runs a real script. There is nothing decorative.

| Control | Runs |
|---|---|
| `HOP` | `zen-hop.sh` — new identity now |
| `DOCTOR` | `doctor.sh` — health check, output in the console pane |
| `◀ PREV` / `NEXT ▶` | `api-keys.sh rotate prev\|next` |
| `ADD` | `api-keys.sh add <key>` (the console validates before it is stored) |
| `CHECK` | `api-keys.sh health` — probes every key |
| `CLEAN` | `api-keys.sh prune` — drops duplicates and rejected keys |
| `DEL` | arm, then confirm within 4 s — `api-keys.sh remove <id>` |
| `WARP` chip | opens the Cloudflare WARP window |
| `PROXY` chip | opens the sheet — the proxy mux and the free-model lever |
| `last session` row | copies the summary to the clipboard |

## The sheet — two levers that do not rotate the tunnel

`PROXY` in the identity row opens a full-panel sheet. It is a sheet, not a
fourth tab: the panel keeps its exact 366×642 and the console keeps its
leftover height, because the sheet covers the panel instead of squeezing it.

Three doors to the same sheet, because a 10px chip is not a way in:

| Door | |
|---|---|
| click `PROXY` | the chip sits at the right end of the meta row, ringed so it reads as a button |
| menu bar icon → `Proxy & Models…` | ⌘⇧P while the HUD is frontmost |
| `printf 'sheet\n' > guard/overlay-cmd` | scripts and the menu share one code path |

**PROXY page** — a local `CONNECT` mux on `127.0.0.1:8899` that rotates
upstream proxies behind one fixed address. The client config never changes, so
a rotation costs no restart, no tunnel, no DNS window.

| Control | Runs |
|---|---|
| `ADD` | `proxy-pool.sh add <spec>` — `host:port:user:pass`, `user:pass@host:port`, or a URL |
| row click | `proxy-pool.sh rotate <n>` — pin that upstream now |
| row `✕` | `proxy-pool.sh remove <n>` |
| `ON` / `OFF` | start/stop the mux; `OFF` also restores the system proxy |
| `ROTATE ⇄` | `proxy-pool.sh rotate` — next upstream, live connections keep running |
| `TEST` | probe every upstream through `cdn-cgi/trace`, record live/dead + ms + exit ip |
| `SYS` | route every app on the machine through the mux (`proxy-pool.sh sys on`) |
| `CONN` | toggle rotation policy: new ip per connection, or one ip held for a window |

The mux fails **closed**: with no live upstream it answers 502 and never falls
back to direct. That is deliberate — the whole point of the layer is that a
dead pool cannot quietly leak the real address.

**MODELS page** — the wall's own text ends with "or switch models", and the
`opencode` provider carries 51 zero-cost chat models. That is 51 free buckets
against the eight `/64`s WARP will hand out, and switching one costs no
registration at all.

| Control | Runs |
|---|---|
| row click | `model-levers.sh set <id>` — writes the CLI default |
| `NEXT ⇄` | next free model this run has not burned |
| `BURN` | marks the current model walled for this run |
| `RESET` | forget the burn list |
| `REFRESH` | re-fetch the catalog (cached 24 h otherwise) |
| `HOP /64` | the expensive lever: rotate the egress identity |

A model switch is never automatic. The running session may not re-read the
config, so an auto-switch on a stale wall can burn three models in one tick;
the HUD makes it one tap and the guard only logs the advice.

## Reading the panel

- **TOKENS · IN + OUT** — straight from `session_v2`, refreshed every 2 s, no cache.
  Beside it: the prompt-cache figure (real work, billed at a fraction), the hit
  rate ring, and the cost column
- **TODAY · RATE/MIN · CACHE HIT · SESSION TIME** — today's tokens, a live delta
  between snapshots (no new tokens, no number), cache hit rate, and total
  create-to-last-activity time across all sessions
- **IDENTITY** — the address the server sees, and the `/64` that is the actual quota key
- **API KEYS** — pool size, which key is live, and `●` for the console's verdict
- **STATUS** — one chip per subsystem; green means the thing it names is live
- **tabs — IDENTITY · KEYS · STATS.** one fixed 118 px pane shared by all
  three, so a new card costs a row inside a pane instead of another slice of
  window. the console sits below the tabs and owns the remaining height, which
  is why it can never be squeezed out again
- **IDENTITY** — egress, quota /64, rotations, device, plus one line: is this
  bucket fresh or burnt, how many walls it has seen, how many buckets have
  burned. red dot on the tab when the current bucket is on the blacklist
- **KEYS** — the pool (add / prev / next / check / clean / delete), count in
  the tab label. the header reads `9/50 · 9 live` from the probe cache, because
  pool size is not capacity: the dot is red only when the console rejects the
  active key and amber when it has not been asked yet
- **STATS** — session burn and the top three models by tokens
- **SESSION BURN** — the last 24 sessions that spent anything, newest last. Bar
  height is real tokens; the green tick above a bar is that session's cache share
- **CONSOLE** — the raw output of whatever you just ran

## Driving it from a script

```bash
ouc hud show          # pin it open
ouc hud summon        # what the lane does
ouc hud hide          # put it away
ouc hud quit          # stop it (boots the agent out so KeepAlive cannot revive it)
ouc hud warp          # open the WARP window
```

Lower level, still supported — the app watches this file every 0.6 s:

```bash
G=~/.local/share/opencode-unlimited/guard
printf 'state\n' > "$G/overlay-cmd"     # writes overlay-state.json
printf 'rect\n'  > "$G/overlay-cmd"     # writes every control's hitbox
printf 'dom\n'   > "$G/overlay-cmd"     # writes what the page is rendering
```

`rect` is how the hitboxes are proven: it emits panel-relative coordinates,
and the click that lands on them is `x = frame.x + c.x + c.w/2`,
`y = screenHeight − (frame.y + frame.height − c.y − c.h/2)`.

## Files

```
scripts/overlay/main.swift      the app (AppKit + WebKit, one file)
scripts/overlay/overlay.html    the entire UI
scripts/overlay/build.sh        swiftc → .app bundle
scripts/proxy-mux.py            the rotating CONNECT proxy behind the sheet
scripts/proxy-pool.sh           its pool CLI (add/list/test/rotate/sys)
scripts/model-levers.sh         the free-model list + CLI default writer
~/Library/Application Support/opencode-unlimited/OpencodeOverlay.app
```
