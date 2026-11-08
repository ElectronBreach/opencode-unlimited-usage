#!/bin/bash
# doctor — tells you what's alive and what needs attention. no fixes, just
# the truth (macOS port). run it whenever something feels off.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
ANCHOR_NAME="OUC_LEAKGUARD"

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/local/bin/warp-cli ]; then WARP=/usr/local/bin/warp-cli
  elif [ -x /opt/homebrew/bin/warp-cli ]; then WARP=/opt/homebrew/bin/warp-cli
  elif [ -x "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" ]; then WARP="/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found — install it first"; exit 1; }

wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo ""
echo "  ============================="
echo "  Opencode Unlimited — doctor (macOS)"
echo "  ============================="
echo ""

# ---- keeper (root LaunchDaemon)
if launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1; then
  ok "keeper daemon (root, launchd)"
else
  bad "keeper down — sudo launchctl bootstrap system /Library/LaunchDaemons/com.opencode-unlimited.keeper.plist"
fi

# ---- cloudflare daemon (its own launchd job)
if launchctl print system/com.cloudflare.1dot1dot1dot1.macos.warp.daemon >/dev/null 2>&1; then
  ok "cloudflare warp daemon"
else
  bad "cloudflare daemon down — keeper re-bootstraps it within ~45s"
fi

# ---- warp tunnel
ST=$(wo status | head -1)
echo "$ST" | grep -q Connected \
  && ok "warp tunnel: connected" \
  || bad "warp not connected — keeper repairs within ~45s (or restart it)"

MODE=$(wo settings 2>/dev/null | awk -F'Mode: ' '/Mode:/ {print $2; exit}')
case "$MODE" in
  TunnelOnly) ok "warp mode: TunnelOnly (dns stays local)" ;;
  Warp)       warn "warp mode: Warp (dns rides the tunnel — keeper will switch it)" ;;
  "")         warn "warp mode: unreadable" ;;
  *)          warn "warp mode: $MODE" ;;
esac

PFX=$(ifconfig 2>/dev/null | awk '/^utun/{i=$1} /inet6 26[0-9a-f]*:/{print $2}' | head -1 | cut -d/ -f1 | awk -F: '{print $1":"$2":"$3":"$4}')
# the quota key is what the server sees (2a09:bac5:...::/64), not the tunnel's
# inside leg (2606:4700:110:...::/64). prefer the recorded seen /64.
SEENPFX=$(python3 -c "import json;print((json.load(open('$GUARD_DIR/state.json')).get('prefix') or ''))" 2>/dev/null)
if [ -n "$SEENPFX" ]; then
  ok "server-seen /64: $SEENPFX (quota key)"
elif [ -n "$PFX" ]; then
  warn "server-seen /64 unknown — tunnel /64 is $PFX (run a hop to record the real one)"
else
  warn "warp ipv6 /64: none — falling back to the 4 v4 addresses"
fi

# ---- leak guard (opt-in)
if [ -f /etc/pf.anchors/OUC_LEAKGUARD ]; then
  RULES=$(sudo -n /sbin/pfctl -a OUC_LEAKGUARD -s rules 2>/dev/null | grep -c . )
  if [ "${RULES:-0}" -gt 0 ]; then
    ok "leak guard armed ($RULES rules, drops non-tunnel egress)"
  else
    warn "leak guard installed but empty (fail-open while the tunnel is down)"
  fi
else
  ok "leak guard off (opt-in default, zero pf risk)"
fi

# ---- egress
IP=$(curl -4 -s -m 10 https://api64.ipify.org 2>/dev/null)
if [ -n "$IP" ]; then
  case "$IP" in
    104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) ok "egress is cloudflare (warp): $IP" ;;
    *) warn "egress is NOT warp ($IP) — tunnel down or fail-open engaged" ;;
  esac
else
  bad "no egress at all — check Wi-Fi first, then the keeper"
fi

# ---- DNS (the thing that bit this machine last time)
if dig +short +time=2 +tries=1 opencode.ai >/dev/null 2>&1 && [ -n "$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null)" ]; then
  ok "dns: opencode.ai resolves ($(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null | head -1))"
else
  bad "dns: opencode.ai does not resolve — keeper restores the baseline automatically, or: sudo dscacheutil -flushcache"
fi

# ---- guard (user LaunchAgent)
if launchctl print "gui/$(id -u)/com.opencode-unlimited.guard" >/dev/null 2>&1; then
  ok "zen-guard agent (user)"
else
  bad "zen-guard down — launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.opencode-unlimited.guard.plist"
fi

# ---- guard state
if [ -f "$GUARD_DIR/state.json" ]; then
  python3 - "$GUARD_DIR/state.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(f"    rotations so far: {d.get('hops',0)} · blacklisted blocks: {len([x for x in d.get('blacklist',[]) if x])}")
    print(f"    identity: {d.get('current') or '?'} · egress /64 {d.get('prefix') or '?'} · device {(d.get('device') or '?')[:8]}…")
    if d.get('seen6'):
        print(f"    ipv6 exit: {d.get('seen6')}")
except Exception as e:
    print(f"    guard state unreadable: {e}")
PY
fi

# ---- TUI shim
if [ -f "$HOME/.local/bin/opencode" ] && grep -q "zen-lane" "$HOME/.local/bin/opencode" 2>/dev/null; then
  ok "opencode entry → lane"
else
  warn "opencode entry doesn't point at the lane — reinstall or check ~/.local/bin/opencode"
fi

# ---- overlay HUD (hop + doctor + live token ledger, one window)
APP="$HOME/Library/Application Support/opencode-unlimited/OpencodeOverlay.app"
if [ -x "$APP/Contents/MacOS/opencode-unlimited-overlay" ]; then
  if pgrep -f "OpencodeOverlay.app/Contents/MacOS/opencode-unlimited-overlay" >/dev/null 2>&1; then
    ok "overlay HUD running (auto-raised by every opencode launch)"
  else
    warn "overlay HUD built but not running — opencode-unlimited-overlay"
  fi
else
  warn "overlay HUD not built — bash $DEST/scripts/overlay/build.sh"
fi

# ---- credit system (AGENTS.md)
[ -f "$HOME/.opencode/AGENTS.md" ] \
  && ok "credit file ~/.opencode/AGENTS.md present (every AI response signs off)" \
  || warn "credit file missing — cp $DEST/AGENTS.md ~/.opencode/AGENTS.md"

echo ""
echo "  all good = work. something red = run the command next to it."
echo ""
