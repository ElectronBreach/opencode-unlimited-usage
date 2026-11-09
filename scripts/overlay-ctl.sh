#!/bin/bash
# opencode-unlimited-overlay — show / hide / drive the HUD.
#
#   opencode-unlimited-overlay            show (launch if needed)
#   opencode-unlimited-overlay toggle     bubble ⇄ panel
#   opencode-unlimited-overlay collapse   → circular bubble
#   opencode-unlimited-overlay expand     → full panel
#   opencode-unlimited-overlay hop        run a rotation from the HUD
#   opencode-unlimited-overlay doctor     run the health check
#   opencode-unlimited-overlay reload     reload the HUD's page (self-heal)
#   opencode-unlimited-overlay summon    show for a session; steps back when it exits
#   opencode-unlimited-overlay hide       put the panel away (menu bar brings it back)
#   opencode-unlimited-overlay close      collapse to the bubble
#   opencode-unlimited-overlay quit       terminate the HUD process
#
# launching is a no-op when it is already up: `open -g` reuses the running
# instance (one HUD per login session, always).
set -u
BRAND="opencode-unlimited"
APP="$HOME/Library/Application Support/$BRAND/OpencodeOverlay.app"
GUARD="$HOME/.local/share/$BRAND/guard"
CMD="$GUARD/overlay-cmd"
[ -d "$APP" ] || { echo "overlay not built — run the installer, or: bash scripts/overlay/build.sh" >&2; exit 1; }
mkdir -p "$GUARD"

running(){ pgrep -f "OpencodeOverlay.app/Contents/MacOS/opencode-unlimited-overlay" >/dev/null 2>&1; }

# the project label comes from whoever launched opencode — write it before
# raising the window so an already-running HUD picks up the new directory.
ctx(){
  [ -n "${OUC_SESSION_DIR:-}" ] || return 0
  python3 - "$GUARD/overlay-context.json" "$OUC_SESSION_DIR" <<'PY' 2>/dev/null || true
import json, sys, time
p, d = sys.argv[1], sys.argv[2]
try: cur = json.load(open(p))
except Exception: cur = {}
if cur.get("dir") == d: sys.exit(0)
json.dump({"dir": d, "ts": int(time.time())}, open(p, "w"))
PY
}

HUD_LABEL="com.opencode-unlimited.overlay"
AGENT="gui/$(id -u)/$HUD_LABEL"
PLIST="$HOME/Library/LaunchAgents/com.opencode-unlimited.overlay.plist"

# `quit` boots the agent out so the app cannot be resurrected by KeepAlive.
# that leaves no crash protection, so a later show puts the agent back first —
# launchd supervises it again and a crash is recovered by the system, not by
# nobody noticing.
ensure_agent(){
  launchctl print "$AGENT" >/dev/null 2>&1 && return 0
  [ -f "$PLIST" ] || return 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || open -g "$APP"
  return 0
}

# start the app under launchd when the agent is installed, so a crash is
# recovered by the system instead of by nobody noticing. otherwise launch it
# directly — same window, no supervisor.
# kickstart cannot pass argv, so intent goes in a file the app reads at boot
# (and ignores if it is older than 15s).
mark_intent(){
  printf '%s %s\n' "${1:-show}" "$(date +%s)" > "$GUARD/overlay-intent" 2>/dev/null || true
}

launch_hud(){
  mark_intent "${1:-show}"
  if launchctl print "$AGENT" >/dev/null 2>&1; then
    launchctl kickstart "gui/$(id -u)/$HUD_LABEL" >/dev/null 2>&1 && return 0
  fi
  open -g "$APP" --args --session-dir "${OUC_SESSION_DIR:-$PWD}" --"${1:-show}"
}

show(){
  ctx
  if running; then
    printf 'expand\n' > "$CMD"
  else
    ensure_agent
    launch_hud show
  fi
}

# the lane's version: same thing, but the HUD knows it was opened for a
# session and steps back once the last one exits.
summon(){
  ctx
  if running; then
    printf 'summon\n' > "$CMD"
  else
    ensure_agent
    launch_hud summon
  fi
}

action="${1:-show}"
case "$action" in
  show)     show ;;
  summon)   summon ;;
  hide)     printf 'hide\n' > "$CMD" ;;
  quit)     printf 'quit\n' > "$CMD" ;;
  close)    printf 'close\n' > "$CMD" ;;
  hop|doctor|toggle|expand|collapse|reload)
            ctx
            running || open -g "$APP" --args --session-dir "${OUC_SESSION_DIR:-$PWD}"
            sleep 0.4
            printf '%s\n' "$action" > "$CMD" ;;
  warp)     printf 'warp\n' > "$CMD" ;;
  *)        echo "usage: $(basename "$0") [show|summon|hide|quit|toggle|collapse|expand|hop|doctor|reload|close|warp]" >&2; exit 2 ;;
esac
