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

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

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
if [ ! -f "$GUARD_DIR/dns-baseline.txt" ]; then
  for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    case "$svc" in \**) continue ;; esac
    s networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 || true
  done
  ok "dns reset to dhcp (no baseline was recorded)"
fi
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
s rm -f "/etc/sudoers.d/$BRAND" "/etc/sudoers.d/${BRAND}-mac" && ok "sudoers entry removed (both names)"

# wrapper — remove it outright. keeping a passthrough shim meant the entry
# survived every uninstall and could shadow a reinstall.
rm -f "$HOME/.local/bin/opencode"
REAL="$(resolve_real_opencode)"
if [ -n "$REAL" ]; then
  ok "opencode entry removed (stock binary still at $REAL)"
else
  warn "opencode entry removed (no real binary found on PATH)"
fi

# credit file (ours only — if the user added their own rules, those stay)
if [ -f "$HOME/.opencode/AGENTS.md" ] && grep -q "ElectronCursed" "$HOME/.opencode/AGENTS.md"; then
  rm -f "$HOME/.opencode/AGENTS.md"
  ok "credit file removed"
fi

# PATH tools
rm -f "$HOME/.local/bin/${BRAND}-hop" "$HOME/.local/bin/${BRAND}-doctor"
rm -f "$HOME/.opencode/bin/${BRAND}-hop" "$HOME/.opencode/bin/${BRAND}-doctor"
rm -f "$HOME/.local/bin/${BRAND}-killswitch" "$HOME/.local/bin/${BRAND}-uninstall"
rm -f "$HOME/.local/bin/${BRAND}-mac" 2>/dev/null || true
rm -rf "$HOME/.local/share/${BRAND}-mac"

# scripts + state. leave warp itself installed (it's a normal app now) —
# a lane killed with -9 skips its trap and leaves a marked block in /etc/hosts.
# strip it here so an uninstalled machine never keeps opencode.ai pinned to an
# edge that no longer exists.
if grep -qF "# >>> opencode-unlimited lane >>>" /etc/hosts 2>/dev/null; then
  HOSTS_TMP=$(mktemp /tmp/ouc-hosts.XXXXXX 2>/dev/null) || HOSTS_TMP=""
  if [ -n "$HOSTS_TMP" ]; then
    awk -v b="# >>> opencode-unlimited lane >>>" -v e="# <<< opencode-unlimited lane <<<" '
      $0==b{skip=1;next} skip&&$0==e{skip=0;next} !skip{print}' /etc/hosts > "$HOSTS_TMP"
    s /bin/cp "$HOSTS_TMP" /etc/hosts && ok "stale lane pin removed from /etc/hosts"
    rm -f "$HOSTS_TMP"
    s dscacheutil -flushcache >/dev/null 2>&1 || true
    s killall -HUP mDNSResponder >/dev/null 2>&1 || true
  fi
fi

# disconnect the tunnel so traffic goes back to your real IP.
rm -rf "$DEST" && ok "scripts + guard state removed"
if command -v warp-cli >/dev/null 2>&1; then
  s warp-cli --accept-tos disconnect >/dev/null 2>&1 && ok "warp tunnel disconnected (app left installed)"
osascript -e 'tell application "System Events" to delete login item "Cloudflare WARP"' >/dev/null 2>&1 || true
fi
dscacheutil -flushcache >/dev/null 2>&1 || true

echo ""
ok "gone. opencode itself + your sessions are untouched."
echo ""
