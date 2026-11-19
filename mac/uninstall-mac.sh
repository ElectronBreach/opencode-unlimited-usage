#!/bin/bash
# opencode-unlimited — macOS uninstaller.
# Removes the agents, the HUD bundle and the lane. Leaves Cloudflare WARP.app
# and your WARP registration untouched.
set -uo pipefail

DEST="$HOME/.local/share/opencode-unlimited"
LANE="$HOME/.local/share/ocu-lane"
BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Library/Application Support/opencode-unlimited/OpencodeOverlay.app"
KEEPER_PLIST="/Library/LaunchDaemons/com.opencode-unlimited.keeper.plist"

say(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

UID_N="$(id -u)"
say "opencode-unlimited — macOS uninstall"

for label in ai.ocul.guard com.opencode-unlimited.overlay \
             com.ouc.guard com.ouc.keeper com.opencode-unlimited.guard; do
  launchctl bootout "gui/$UID_N/$label" >/dev/null 2>&1 && ok "booted out $label"
  launchctl disable "gui/$UID_N/$label" >/dev/null 2>&1 || true
  rm -f "$AGENTS/$label.plist" 2>/dev/null
done

if launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null || sudo -v; then
    sudo launchctl bootout system/com.opencode-unlimited.keeper >/dev/null 2>&1 \
      && ok "booted out keeper daemon"
    sudo rm -f "$KEEPER_PLIST"
  else
    warn "run as root to remove the keeper:"
    warn "  sudo launchctl bootout system/com.opencode-unlimited.keeper && sudo rm -f $KEEPER_PLIST"
  fi
fi

rm -rf "$APP" && ok "removed HUD bundle"
rm -f "$BIN/ocul" "$BIN/ouctl" "$BIN/hop" && ok "removed launchers"
rm -rf "$LANE" && ok "removed lane state"

say ""
say "kept: $DEST (scripts + guard state) and WARP itself"
echo "  remove fully:  rm -rf \"$DEST\" \"$HOME/Library/Application Support/opencode-unlimited\""
