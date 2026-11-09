# Changelog

All notable changes to the macOS port. Versioned by the `VERSION` file; the
Linux upstream has its own history.

## 2.4.8 — 2026-11-09

### Rotation was judging the wrong provider

With a provider model pinned (`river/DeepSeek-V4.1-Flash-1017`), the console
key rotation probed that model id against the **opencode console** endpoint,
got `400 unavailable` for all nine keys, and refused to rotate a pool that was
perfectly healthy. The pool owns one provider; a model from another one is not
its business.

- rotation gates (pre-flight and post-swap verify) now run only when the pinned
  model's provider matches the credential provider;
- `model-levers set <provider>/<model>` pins any model that exists in the
  config, so escaping an exhausted free tier is one command, not a hand-edited
  json;
- the pre-flight pass still stops the pointless case: when every key reports
  the *same* verdict for a console model, it says "this pool shares one quota,
  rotation cannot bypass it" and leaves the pool alone;
- the fallback no longer leaves the session on a model that just failed — it
  commits only a model that answered, and otherwise restores the previous pin.

Verified end to end: `rotate next` with the river model pinned moves
`OpenCode Console 4 → 5` and stops there; with the free model pinned it says
"every key reports … as unavailable — that is the model, not the key"; and
`opencode run` answers on the river pin.

## 2.4.7 — 2026-11-09

### Key rotation is not quota rotation

The rotation had a gate that skipped any key whose model probe returned 429 or
400. That was wrong twice over: a 429 is a fact about the **model**, not the
credential, and it made a pool of nine valid keys refuse to rotate at all.

- the gate is gone — rotation walks keys that the console accepts, full stop;
- after the swap it asks the pinned model on the new key, and if that model
  does not answer it moves the model to one that does (verifying the pick, up
  to three tries, marking each failure in the dead cache);
- when nothing answers it says the true thing: **the opencode free pool is
  exhausted account-wide, key rotation cannot bypass it** — use a provider
  model or wait for the reset. No more "rotated → Model unavailable".

**`api-keys quota [model]`** is the missing question answered in one pass: for
the pinned model, how many keys answer, how many are at the wall, how many do
not serve it. If every key reports the same wall, the command says so.

**`doctor`** now prints the probe verdict: `! 17 of 50 free models are walled
or unavailable right now`, and calls it a failure when the whole free pool is
in the dead cache.

## 2.4.6 — 2026-11-09

### The pool that emptied itself

`proxies.txt` went empty twice with no explanation, taking the mux with it. It
now has a paper trail and a seatbelt:

- every add and remove writes `guard/proxy-mutations.log` with the count, the
  parent pid and the parent's argv, so the next disappearance names its caller;
- `remove` refuses to delete the **last** upstream unless `--force`, because a
  pool of zero is a mux that cannot start;
- every add keeps `proxies.last`, and `on` restores from it when the pool file
  arrives empty instead of dying.

### restart cli told the truth, finally

The service inherits env from the **CLI process**; killing the service only
helps when the CLI already carries the proxy env. So the amber hint now says
`restart opencode`, and the button's toast says what to do if the hint stays.
`proxy-pool cli` is still there for the case it does fix, and it self-heals the
CLI shim first.

`scripts/opencode.shim` now logs its decision when `OUC_SHIM_DEBUG=1` is set
(`guard/shim.log`), because "did the shim even run" was not answerable by
looking at the machine.

## 2.4.5 — 2026-11-09

### The restart button was a lie, and the rotation walked off its provider

**The CLI shim.** `serve --service` inherits env from the CLI that spawned it,
so killing it never helped: the new one was born with the same old env. The fix
is at the binary path — `scripts/opencode.shim` sits at `opencode.exe`, reads
the mux state, exports `HTTP(S)_PROXY`, then execs `opencode.real`. Every
future service is born proxied, including in a session that started before the
proxy existed. Verified: a service spawned by a CLI with **no** proxy env came
up with `HTTPS_PROXY=http://127.0.0.1:8899`, and `served` on the mux moved.

- `proxy-pool shim on|off|status`, and `proxy-pool cli` self-heals the shim
  before it restarts the service, because an npm update drops it.
- the shim resolves `$0` through the `~/.npm-global/bin` symlink first — the
  first cut used `dirname $0` and every launch died with "cannot execute".
- lane, doctor and pool matchers now accept `opencode.real`, since the shim
  execs the real binary and the process name changes with it.

**Rotation stays on the model's provider.** Rotating credentials is not
model-agnostic: the pool holds `nvidia` keys next to `opencode` console keys,
and rotating onto the wrong provider is exactly `Model unavailable`. Rotation
now asks the console about the pinned model, one token, and skips a key that
answers 429 (free wall) or 400 (model not served there), saying which and why
instead of landing on it.

**The model lever remembers.** `model-levers dead <id> [429|400]` records a
model the console is not serving, `next` skips it (30 min for a wall, 6 h for
"unavailable"), `probe [n]` fills the cache by asking, and `zen-guard` marks
the active model when the CLI reports `ModelUnavailableError`.

**Smaller honesty fixes**

- a fresh mux no longer says "nothing probed yet" when the last TEST wrote a
  verdict a second earlier: `seen` is seeded from the health file, live or dead;
- `doctor` now prints `✓ cli shim installed` and `✓ opencode service → mux`.

## 2.4.4 — 2026-11-09

### 502 as a transient, not a verdict

`ERR_PROXY_TUNNEL: Proxy refused to open a tunnel: 502` was the mux doing the
honest thing at the wrong moment: one failed connect parked the only upstream
for a flat **60 seconds**, and every request in those 60s was refused without
an attempt. A webshare line that drops one connection read as a dead pool.

- **park with backoff, not a flat minute** — 4s, 8s, 16s, 32s, capped at 60,
  and a good connect clears the record so the ladder starts over.
- **one retry before parking** — a mid-handshake drop gets a second attempt
  350ms later, which is what usually lands.
- **never refuse without trying** — when every upstream is parked the mux
  probes the one that has sat out longest instead of answering 502 immediately.
- **every park is logged** with the reason, in `guard/proxy-mux-events.log`.

### The mux stays up while it is wanted

`proxy-pool on` writes `guard/proxy-want`. `zen-guard` restarts a mux that
died while that marker exists, so a crash or a stray `pkill` cannot silently
drop the CLI back to direct egress. `proxy-pool off` removes the marker and is
still the only thing that stops it on purpose.

### The lane stops being a coin flip

`zen-lane.sh` exported the proxy only when the mux pid was live. A CLI launched
during a 6s restart window was born **direct** and stayed direct for hours.
It now exports whenever the pool is non-empty and the mux is either up or
wanted — the guard covers the window in between.

### Bulk import, because rotation needs two

A single upstream means a single egress ip, so "rotate" cannot change identity
no matter how often it is pressed. `proxy-pool import <file|url>` takes a whole
webshare export (csv or `host:port:user:pass`, header rows skipped, duplicates
dropped) and `doctor` says out loud when the pool is one line.

### One tap to restart the CLI service

`proxy-pool cli` stops the `serve --service` child so the CLI spawns a fresh
one with the current env, and the amber `restart cli` in the sheet's status
line is now a button that runs it. It cannot rewrite the env of a CLI that was
already born without it — the TUI has to be relaunched once — but after that
first relaunch the lane keeps every future service proxied, so the hint stops
appearing on its own.

### docs

`doctor` and the sheet keep naming the two states that matter: pool of one
cannot rotate, and a CLI service born before PROXY ON keeps its old env.

## 2.4.3 — 2026-11-09

### PROXY ON now means the CLI, not just the mux

Two bugs stood between the sheet and a real rate-limit bypass, and they hid
each other.

**The probe URL was not a host.** `proxy-pool test` curled
`https://cdn-cgi/trace` — no such hostname. Every upstream probed dead,
including a perfectly good webshare line. Now the probe hits an ip literal
(`https://1.1.1.1/cdn-cgi/trace`), then two plain-ip services for proxies that
refuse CONNECT to 1.1.1.1, and reads a bare ip body as a pass.

**The CLI never used the mux.** Rotation only helps a client that points at the
door, and the process that opens the sockets is `opencode.exe serve --service`
— a long-lived child of the CLI that inherits env at spawn. So:

- `zen-lane.sh` exports `HTTP(S)_PROXY` → `127.0.0.1:8899` when the mux is up
  and the pool is non-empty, and skips the export when it is not;
- a service left over from the other state is restarted at launch — started
  before PROXY ON it bypasses the mux, started before PROXY OFF it points at a
  dead port. Only orphans are touched, never a live session's service;
- `pgrep` cannot see that process (session leader), so both the lane and
  `doctor` enumerate `ps -Ao pid=,args=` instead. The first cut silently found
  nothing, which is the worst kind of safety check.

**Honesty:** `healthy` in the mux state counted the *expired* dead entries —
the inverse of its label — so a good single-upstream pool read `0 of 1`. It now
counts pool minus parked. `tested` counts upstreams with a verdict. `doctor`
prints `! opencode service bypasses the mux — restart the CLI`, and the sheet's
status line shows an amber `restart cli` when it does.

Verified: webshare `198.23.243.226:6361` → `TEST` ok 1030ms → `curl` through
the mux `198.23.243.226` → bun fetch through the mux `198.23.243.226`,
`served` incremented.

## 2.4.2 — 2026-11-09

### A green tick over a dead port

`SYS` points every app on the machine at `127.0.0.1:8899`. If the mux is not
running that is not "routed through the mux", it is a dead internet with a ✓
next to it — and `doctor` printed exactly that ✓, because it checked
`scutil --proxy` and never checked for a listener.

- **doctor** now needs both: macOS pointed at the mux *and* the mux alive. A
  pointed-but-dead config prints `✗ … every app is talking to a dead port`.
- **proxy-mux** restores the saved system baseline on the way out. `SIGTERM`
  is turned into a clean exit so the `finally` runs.
- **zen-guard** is the net under that: if the state file says `system:true`
  and `up:false`, it puts the baseline back within one 6s tick and logs it.
  A `kill -9` cannot skip a `finally`; it still cannot skip the guard.

## 2.4.1 — 2026-11-09

### Three doors to the sheet

The chip worked and the chip was unfindable: a 10px text run at the right end
of a 7.5px meta row. Same sheet, two more ways in, no pixels added.

- the chip is now ringed, so it reads as a control instead of a label;
- **menu bar → `Proxy & Models…`** (⌘⇧P when the HUD is frontmost) opens the
  panel and the sheet in one move;
- **`sheet`** in `guard/overlay-cmd` opens it from a script. The menu item and
  the file command call the same `openSheet()`, so the two doors cannot drift.

Debug plumbing that made the blank-sheet report answerable: **`eval`** in
`guard/overlay-cmd` runs whatever JS sits in `guard/overlay-eval.js` and writes
the result to `guard/overlay-eval.json`. The blank was a capture taken during
the relaunch — the sheet's own geometry reads `head y=10 h=20`, `list y=67
h=460`, `add y=534`, all visible at opacity 1.

## 2.4.0 — 2026-11-09

### Two levers that are cheaper than a rotation

A `/64` rotation is a full disconnect, a re-register, a reconnect, and a
blacklist check before the landing can even be trusted. It is the right first
move for an ip-keyed wall and the wrong first move for everything else, so the
sheet now carries the two levers that cost nothing.

**The free tier is per model.** The client's own wall text is the spec:
"Free usage limit reached. Connect a provider or subscribe to OpenCode Go to
keep going, **or switch models**." The catalog at `models.opencode.ai` lists
**51 zero-cost chat models** on the `opencode` provider — 51 buckets against
the eight `/64`s WARP hands out, and a switch is one key in
`~/.config/opencode/opencode.json`. No tunnel, no registration, no DNS window.

- `model-levers.sh` — `list`, `current`, `set`, `next`, `burn`, `burn-current`,
  `reset`, `refresh`, `json`. Catalog cached 24 h (it is 10 MB; the status hot
  path never touches it)
- the switch stays **manual**. A session that already took a wall may not
  re-read the config, so an automatic switch could burn three models in one
  tick on a stale wall. The guard logs the advice instead

**A rotating proxy in front of the tunnel.** `proxy-mux.py` takes `CONNECT` on
`127.0.0.1:8899` and dials an upstream behind it. The client config is written
once, so rotating is a pointer move: no restart, no tunnel rebuild, no DNS
window. `conn` gives a new upstream per connection, `window` holds one for a
while.

- accepts `host:port:user:pass` (webshare's export), `user:pass@host:port`, and
  URL forms; `http`, `https`, `socks5`, `socks5h`; deduped, capped at 200
- a failed upstream is parked 60 s, the connection retries on the next live one
- **fails closed**: no live upstream answers 502. An egress layer that falls
  back to direct is not an egress layer
- `proxy-pool.sh` — `add`, `list`, `remove`, `test`, `on`, `off`, `rotate`,
  `policy`, `sys`, `status`, `json`; `sys` routes the whole machine through the
  mux and restores the saved baseline on `off`

### The sheet, without growing the panel

`PROXY` is a chip in the identity row, not a fourth tab. It opens a full-panel
sheet with `PROXY | MODELS` pages, so the panel keeps its exact **366×642** and
the console keeps every pixel of its leftover height.

- each page has its own status line, and a poll that lands while the other page
  is open cannot repaint it
- `TEST` hands its verdict to the running mux (`reload`), so the sheet and the
  mux cannot disagree about a pool one of them just proved dead
- the models tab carries the unburned count in the tab itself (`51/51`)

### Honesty fixes found while wiring it up

- **a fresh mux lied about health.** With a dead pool it reported "2 of 2
  healthy" until the first connection failed. Health now counts only upstreams
  the mux has actually tried (`healthy` / `tested`), and `doctor.sh` says
  "nothing probed yet" instead of a green tick
- **the mux started blind.** It now seeds its dead set from the last `TEST`
  (`proxy-health.json`, 900 s TTL), so a pool that was just proven dead is
  skipped from the first connection
- **`count()` printed two zeros.** `grep -c` prints `0` *and* exits 1, so
  `|| echo 0` produced `"0\n0"` and every arithmetic test blew up
- **`state_up()`** — a stale `"up": true` after a kill no longer reads as
  running, because the pid is checked, not just the file
- `doctor.sh` now verifies the `SYS` claim against `scutil --proxy` instead of
  trusting the flag, and reports the model lever without false green

### Install parity

- the mux is python, and every copy path took `*.sh` only — `install.sh`,
  `tools/embed.sh` and `make release` now carry `scripts/*.py` too
- the remote fetch list covers every script the macOS build ships, not just the
  eight originals

### The guard says when the ip is not the problem

Three walls inside a minute of a fresh identity, or a saturated `/64` pool,
means the wall is account-side. The guard now logs "the wall is not the ip right
now — HUD → PROXY → MODELS, pick a free model" at that point, once, and parks
rotations. It does not touch the config itself.

## 2.3.0 — 2026-11-09

### A burnt bucket is not a fresh identity

The retry loop compared each landing against the block it had just left — and
against nothing else. So it accepted a block burned hours earlier and printed a
green tick. The log proves the cost: `b40:8` took a wall at **01:05** and took
another at **10:08**, three minutes after we landed back on it. Nine hours
apart, still burnt.

- every landing is now checked against the blacklist, not just against the old
  block
- collisions are counted, and eight tries that all land on burned blocks are
  reported as a **saturated pool** instead of a rotation
- upstream's "recycle the oldest block" fallback is gone — measured wrong here,
  it was a second wall wearing a rescue's clothes
- parked rotations (`last_hop` in the future) no longer read as "a wall zero
  seconds after a rotation", which was refilling the fast-wall counter and
  re-parking on every tick

### The key pool lied about being a lever

`api-keys list` cached a **live** verdict for ten minutes. A key revoked a
minute after a probe still painted a green dot and `rotate` would pick it.
`health` probed every key but never wrote the verdict, so the cache never
learned anything.

- alive verdicts expire in **60 s**; rejected ones stay 10 min (a dead key does
  not come back)
- `health` now records what it saw
- `status.sh` and the HUD publish **live / dead / unknown**, and the KEYS header
  reads `9/50 · 9 live` instead of the pool size pretending to be capacity
- the dot is red only when the console rejects the active key, amber when it has
  not been asked
- `doctor.sh` says "none verified yet" rather than claiming every key is
  rejected when it simply has not probed

### The key lever is a fallback, not the first move

Wall handling stays ip-first, because the ip is what has cleared walls on this
machine every single time. When the `/64` pool is saturated, the guard makes one
console-key swap as the last lever — no registration, no tunnel, no window where
dns is in flux — and if a wall comes back after it, the verdict is recorded and
the lever is off for the rest of the run.

Measured here: a fresh bucket lasts **20–30 minutes** of active use, and the
WARP pool hands out a new `/64` most registrations but repeats often enough that
collision handling matters more than retry count.

## 2.2.0 — 2026-11-09

### The rotation was lying about half the time

The quota is keyed on the **egress IPv6 /64** cloudflare hands the server —
not on the device id, and not on the v4 address in front of it. The old check
accepted "registration id changed" as proof of a rotation, so a fresh
registration that landed inside the *same* /64 printed a green tick, you
re-sent the message, and hit the same wall. It looked like the tool was broken
because half the time it was a no-op with good manners.

- New `scripts/zen-identity.sh` — one shared definition of identity, used by
  both `zen-guard.sh` and `zen-hop.sh`. A rotation is real when the egress /64
  changes; anything else is evidence, never the key.
- `zen-hop.sh` now verifies the bucket, and takes one more swing when
  cloudflare hands back the block it just gave you.
- The guard's retry loop judges the bucket too, so a same-/64 registration
  costs one retry instead of a false success.
- `zen-hop.sh --where` prints the live bucket, both egress families, the
  device id and the blacklist without touching the tunnel.

### The blacklist had three kinds of junk in it

`state.json` was holding the tunnel's **inside leg** (`2606:4700:110:*`), bare
v4 duplicates of blocks already listed, and entries twice over. None of them
could ever match a bucket, and they occupied the cap forever.

- `oui_bl_migrate` repairs it once at guard start (14 → 5 entries here).
- Only egress blocks are accepted into the list now; everything else is refused.

### Fewer wasted registrations

- A `connect` that has not settled yet used to be probed once and declared
  dead — six "failures" in a row on a tunnel that was still coming up. The
  guard now waits up to 12 s for a real egress before spending another one.
- Three walls inside a minute of a fresh identity is the **account**, not the
  ip. The guard parks rotations for 15 minutes instead of burning the /64 pool.
- Cooldown escalates to 60 s when a wall lands within three minutes of a hop,
  and the "waiting" line is logged once per episode instead of every 6 s.

### The panel stopped growing

- Three tabs — **IDENTITY · KEYS · STATS** — sharing one fixed 118 px pane.
  Adding a card later costs a row inside a pane, not another 90 px of window.
- The console sits *below* the tabs and keeps the leftover height, so it can
  never be squeezed out by a new card again. Panel 736 → 642 px.
- Identity gained the three facts that matter: which bucket we are on, whether
  it is burnt, and how many have burned. Stats gained the top three models.
- The identity tab carries a red dot when the current bucket is on the
  blacklist — the one thing you should see without opening the tab.

### Also

- `status.sh` publishes `bucket`, `burnt`, `bucketWalls` and `bucketHops`;
  `doctor.sh` prints them.
- `guard/identities.json` — a small per-bucket ledger (walls, hops, first/last
  seen), bounded at 400 buckets.

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
