#!/bin/bash
# clean removal (macOS) — launchd units, pf anchor, sudoers entry, wrapper,
# credit file. your opencode data/sessions/auth are untouched.
#
# works interactively (terminal password) and headless (SUDO_ASKPASS, or
# `printf 'pw\n' | bash uninstall.sh`).
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
DAEMON_LABEL="com.opencode-unlimited.keeper"
AGENT_LABEL="com.opencode-unlimited.guard"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
ANCHOR_NAME="OUC_LEAKGUARD"
ANCHOR="/etc/pf.anchors/$ANCHOR_NAME"
PF_CONF="/etc/pf.conf"

ok(){ echo -e "  \e[32m✓\e[0m $*"; }
warn(){ echo -e "  \e[33m!\e[0m $*"; }

# sudo that works from a terminal, an askpass helper, or piped stdin
s(){
  if sudo -n true 2>/dev/null; then sudo "$@"
  elif [ -n "${SUDO_ASKPASS:-}" ] && sudo -A true 2>/dev/null; then sudo -A "$@"
  elif [ -t 0 ]; then sudo "$@"
  else sudo -S "$@"
  fi
}

resolve_real_opencode(){
  local c
  for c in "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode "$HOME/.npm-global/bin/opencode"; do
    [ -x "$c" ] || continue
    grep -qI "zen-lane\|scripts/lane.sh" "$c" 2>/dev/null && continue
    printf '%s' "$c"; return 0
  done
  return 1
}

echo ""
echo "  removing Opencode Unlimited Usage (macOS)…"
echo ""

# stop services first
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 && ok "zen-guard stopped"
rm -f "$AGENT_PLIST"

s launchctl bootout system/"$DAEMON_LABEL" >/dev/null 2>&1 && ok "keeper stopped"
s rm -f "$DAEMON_PLIST"

# DNS back to the captured baseline BEFORE the state dir goes away
if [ -f "$GUARD_DIR/dns-baseline.txt" ]; then
  while IFS=$'\t' read -r svc servers; do
    [ -n "$svc" ] || continue
    networksetup -listallnetworkservices 2>/dev/null | grep -qx "$svc" || continue
    if [ -z "$servers" ] || [ "$servers" = "Empty" ]; then
      networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 || true
    else
      # shellcheck disable=SC2086
      networksetup -setdnsservers "$svc" $servers >/dev/null 2>&1 || true
    fi
  done < "$GUARD_DIR/dns-baseline.txt"
  ok "dns restored to baseline"
fi
dscacheutil -flushcache >/dev/null 2>&1 || true
killall -HUP mDNSResponder >/dev/null 2>&1 || true

# leak guard — flush first so traffic is free immediately, then remove refs
s /sbin/pfctl -a "$ANCHOR_NAME" -F all >/dev/null 2>&1
if [ -f "$PF_CONF" ]; then
  s python3 - "$PF_CONF" "$ANCHOR_NAME" <<'PY' 2>/dev/null
import sys
path, name = sys.argv[1:3]
lines = open(path).read().splitlines()
drop = {f'anchor "{name}"', f'load anchor "{name}" from "/etc/pf.anchors/{name}"'}
open(path, "w").write("\n".join(l for l in lines if l.strip() not in drop) + "\n")
PY
  s /sbin/pfctl -f "$PF_CONF" >/dev/null 2>&1
fi
s rm -f "$ANCHOR" "$PF_CONF.ouc.bak"
ok "leak guard removed (pf back to stock)"

# sudoers entry
s rm -f "/etc/sudoers.d/$BRAND" && ok "sudoers entry removed"

# wrapper — restore direct access to the real binary if it still exists
REAL="$(resolve_real_opencode)"
if [ -n "$REAL" ]; then
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL" > "$HOME/.local/bin/opencode"
  chmod +x "$HOME/.local/bin/opencode"
  ok "opencode entry → stock binary ($REAL)"
else
  rm -f "$HOME/.local/bin/opencode"
  warn "opencode entry removed (no real binary found to restore)"
fi

# credit file (ours only — if the user added their own rules, those stay)
if [ -f "$HOME/.opencode/AGENTS.md" ] && grep -q "ElectronCursed" "$HOME/.opencode/AGENTS.md"; then
  rm -f "$HOME/.opencode/AGENTS.md"
  ok "credit file removed"
fi

# PATH tools
rm -f "$HOME/.local/bin/${BRAND}-hop" "$HOME/.local/bin/${BRAND}-doctor"

# scripts + state. leave warp itself installed (it's a normal app now) —
# disconnect the tunnel so traffic goes back to your real IP.
rm -rf "$DEST" && ok "scripts + guard state removed"
if command -v warp-cli >/dev/null 2>&1; then
  s warp-cli --accept-tos disconnect >/dev/null 2>&1 && ok "warp tunnel disconnected (app left installed)"
fi
dscacheutil -flushcache >/dev/null 2>&1 || true

echo ""
ok "gone. opencode itself + your sessions are untouched."
echo ""
