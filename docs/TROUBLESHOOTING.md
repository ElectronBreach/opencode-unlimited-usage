# Troubleshooting

Start with `ouc doctor`. It prints one line per subsystem; the line that is red
names the command that fixes it.

## The browser has no internet but `dig` works

This is the failure this build exists to prevent, and it is the one that looks
most like "the Mac is broken".

`getaddrinfo` is wedged while DNS over TCP still answers. Browsers and `curl`
use the first one, `dig` uses the second.

```bash
python3 -c "import socket; print(socket.getaddrinfo('github.com',443))"
```

If that hangs or fails while `dig github.com` answers, repair it:

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

The keeper does this by itself at most once every two minutes; `ouc doctor`
reports it as `dns: system resolver healthy (getaddrinfo)`.

## Cloudflare WARP will not open

Two different things:

- the **tunnel** — root daemon, held by the keeper. `ouc doctor` shows
  `warp tunnel: connected`.
- the **window** — a menu bar app. After sleep it can come back with a 0×0
  window, so clicking it does nothing.

```bash
ouc hud warp          # opens it
```

If the window still does not appear, restart just the GUI (the tunnel is in a
separate daemon and never notices):

```bash
pkill -f "Cloudflare WARP.app/Contents/MacOS/"; open -a "Cloudflare WARP"
```

The HUD now checks every 4 s for a real window and does this itself, at most
once every 10 minutes.

## The HUD is not on screen

```bash
ouc hud show
```

If that does nothing, check why it is not staying up:

```bash
ouc logs overlay | tail -20
```

`no opencode session and no launch intent — exiting` means it started with
nothing to attach to, which is the intended behaviour. Start opencode, or
`ouc hud show` to pin it.

## The HUD will not quit

`✕` hides. To actually stop it:

```bash
ouc hud quit
```

That boots the LaunchAgent out, so `KeepAlive` cannot bring it back. The next
`ouc hud show` (or the next opencode launch) bootstraps it again.

## "Model unavailable" right after a rotation

The CLI caches the console model list per credential id. Swapping the active
key invalidates it. `api-keys.sh rotate` warms the cache and touches
`~/.config/opencode/opencode.json` to force the provider reload; if it still
happens, re-send once — the refetch is already in flight.

## A key keeps getting skipped

`ouc keys health` shows what the console said about each one. A key the console
rejects (`401/403`) is skipped by rotation and removed by `ouc keys prune`.
A key that times out is *not* treated as dead — a slow network is not a bad
key.

## The free-tier wall hit again

Expected eventually — that is what the rotation is for.

```bash
ouc hop
```

New WARP identity, new `/64`, new edge pin. The burned block goes on the
blacklist for good.

## Everything is broken, start over

```bash
~/workspace/opencode-unlimited-usage-mac/uninstall.sh
~/workspace/opencode-unlimited-usage-mac/install.sh
```

`uninstall.sh` restores DNS from the captured baseline and removes the sudoers
entry, the launch agents and the daemon. The HUD goes with them.

## Logs

```bash
ouc logs keeper     # root daemon: tunnel, DNS, egress
ouc logs guard      # the wall watcher
ouc logs overlay    # the HUD: launches, loads, exits
```

`ouc paths` prints every file the install owns.
