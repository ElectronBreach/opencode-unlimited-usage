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
| `last session` row | copies the summary to the clipboard |

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
~/Library/Application Support/opencode-unlimited/OpencodeOverlay.app
```
