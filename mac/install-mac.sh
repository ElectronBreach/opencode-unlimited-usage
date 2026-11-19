#!/bin/bash
# opencode-unlimited — macOS installer
#
# Clones clean, installs clean. One rotator, one keeper, one HUD, one shared
# rotation lock, unlimited rotation.
#
# The root repo is Linux + systemd. macOS has no systemd and no `unshare -rm`,
# so this directory is the macOS implementation:
#
#   rotator   ai.ocul.guard                     (launchd user agent, ocul.py)
#   keeper    com.opencode-unlimited.keeper     (launchd root daemon, warp-keeper.sh)
#   HUD       com.opencode-unlimited.overlay    (OpencodeOverlay.app, built here)
#
# Requirements: Cloudflare WARP.app, warp-cli, python3, Xcode CLT (swiftc).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/opencode-unlimited"
SCRIPTS="$DEST/scripts"
LANE="$HOME/.local/share/ocu-lane"
BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Library/Application Support/opencode-unlimited/OpencodeOverlay.app"
KEEPER_PLIST="/Library/LaunchDaemons/com.opencode-unlimited.keeper.plist"
PLATFORM_PATH="/opt/homebrew/bin:/usr/local/bin:$BIN:/usr/bin:/bin:/usr/sbin:/sbin"

say(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
die(){ bad "$*"; exit 1; }

say "opencode-unlimited — macOS"

# ---------------------------------------------------------------- prereqs ---
WARP=""
for c in "$(command -v warp-cli 2>/dev/null || true)" \
         /usr/local/bin/warp-cli /opt/homebrew/bin/warp-cli \
         "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"; do
  [ -n "$c" ] && [ -x "$c" ] && WARP="$c" && break
done
[ -n "$WARP" ] || die "warp-cli not found — install Cloudflare WARP.app first"
ok "warp-cli: $WARP"

[ -d "/Applications/Cloudflare WARP.app" ] || die "/Applications/Cloudflare WARP.app missing"
command -v python3 >/dev/null 2>&1 || die "python3 missing — brew install python@3.13"
ok "python3: $(command -v python3)"

HAVE_SWIFTC=0
command -v swiftc >/dev/null 2>&1 && HAVE_SWIFTC=1
if [ "$HAVE_SWIFTC" = 1 ]; then
  ok "swiftc: $(command -v swiftc)"
else
  warn "swiftc missing — the HUD cannot be built (xcode-select --install)"
fi

# ---------------------------------------------------------------- dirs ------
mkdir -p "$DEST/guard" "$DEST/logs" "$SCRIPTS" "$LANE" "$BIN" "$AGENTS" \
         "$HOME/Library/Application Support/opencode-unlimited" \
         "$HOME/.local/state/ocu-lane"
ok "directories"

# ---------------------------------------------------------------- rotator ---
install -m 0755 "$REPO_DIR/ocul.py" "$LANE/ocul.py"
install -m 0755 "$REPO_DIR/ouctl"   "$BIN/ouctl"
ok "rotator   -> $LANE/ocul.py"
ok "ouctl     -> $BIN/ouctl"

# ---------------------------------------------------------------- scripts ---
for f in "$REPO_DIR"/scripts/*; do
  [ -f "$f" ] || continue
  install -m 0755 "$f" "$SCRIPTS/$(basename "$f")"
done
ok "scripts   -> $SCRIPTS ($(ls -1 "$REPO_DIR/scripts" | wc -l | tr -d ' ') files)"

# ---------------------------------------------------------------- HUD -------
if [ "$HAVE_SWIFTC" = 1 ]; then
  if bash "$REPO_DIR/overlay/build.sh" "$APP" >/dev/null 2>&1; then
    ok "HUD built -> $APP"
  else
    warn "HUD build failed — run: bash $REPO_DIR/overlay/build.sh"
  fi
else
  warn "skipped HUD build (no swiftc)"
fi

# ---------------------------------------------------------- render plists ---
render(){  # render <template> <output>
  sed -e "s|__HOME__|$HOME|g" \
      -e "s|__WARP__|$WARP|g" \
      -e "s|__PATH__|$PLATFORM_PATH|g" "$1" > "$2"
  plutil -lint "$2" >/dev/null 2>&1 || die "rendered plist is invalid: $2"
}

render "$REPO_DIR/plists/com.opencode-unlimited.overlay.plist.tmpl" \
       "$AGENTS/com.opencode-unlimited.overlay.plist"
ok "plist     -> com.opencode-unlimited.overlay"

# ---------------------------------------------------------- rotator agent ---
# ocul install writes ~/.local/bin/ocul and ai.ocul.guard with this home baked.
# an earlier `ouctl uninstall` or launchctl disable leaves the label disabled
# and bootstrap fails; enable before installing.
launchctl enable "gui/$(id -u)/ai.ocul.guard" >/dev/null 2>&1 || true
python3 "$LANE/ocul.py" install >/dev/null 2>&1 \
  && ok "agent     -> ai.ocul.guard (loaded)" \
  || warn "ai.ocul.guard load failed — run: ocul install"

# ---------------------------------------------------------- overlay agent ---
# a previous uninstall or `launchctl disable` leaves the label disabled, and a
# bootstrap against a disabled label fails with "Input/output error" (EIO).
# enable first, then load.
launchctl bootout "gui/$(id -u)/com.opencode-unlimited.overlay" >/dev/null 2>&1 || true
launchctl enable "gui/$(id -u)/com.opencode-unlimited.overlay" >/dev/null 2>&1 || true
if [ -d "$APP" ]; then
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.opencode-unlimited.overlay.plist" >/dev/null 2>&1 \
    && ok "agent     -> com.opencode-unlimited.overlay (loaded)" \
    || warn "overlay agent load failed — launchctl bootstrap gui/$(id -u) $AGENTS/com.opencode-unlimited.overlay.plist"
else
  warn "HUD bundle missing — overlay agent not loaded"
fi

# ---------------------------------------------------------- root keeper -----
say "keeper daemon (needs sudo once)"
if launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1; then
  ok "keeper already running"
else
  TMP="$(mktemp)"
  render "$REPO_DIR/plists/com.opencode-unlimited.keeper.plist.tmpl" "$TMP"
  if sudo -n true 2>/dev/null || sudo -v; then
    sudo install -m 0644 -o root -g wheel "$TMP" "$KEEPER_PLIST"
    sudo launchctl bootout system/com.opencode-unlimited.keeper >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "$KEEPER_PLIST" >/dev/null 2>&1 \
      && ok "keeper    -> system/com.opencode-unlimited.keeper (root)" \
      || warn "keeper bootstrap failed — sudo launchctl bootstrap system $KEEPER_PLIST"
  else
    warn "no sudo — install the keeper later:"
    warn "  sudo install -m 0644 -o root -g wheel $TMP $KEEPER_PLIST"
    warn "  sudo launchctl bootstrap system $KEEPER_PLIST"
    KEEP_TMP="$TMP"
  fi
  [ "${KEEP_TMP:-}" = "$TMP" ] || rm -f "$TMP"
fi

# ---------------------------------------------------------- one rotator -----
say "consolidating (removes duplicate rotators)"
"$BIN/ouctl" consolidate >/dev/null 2>&1 || true
ln -sf "$BIN/ouctl" "$BIN/hop" 2>/dev/null || true

# ---------------------------------------------------------- dead switch -----
# a leftover proxy.off silently disables lane self-heal forever
if [ -f "$HOME/.local/state/ocu-lane/proxy.off" ]; then
  rm -f "$HOME/.local/state/ocu-lane/proxy.off"
  warn "removed a stale proxy.off kill switch"
fi

# ---------------------------------------------------------- verify ----------
say ""
say "verify"
"$BIN/ocul" doctor 2>&1 | sed -n '1,25p' || true

say ""
say "installed. next:"
echo "  ouctl doctor     # health + duplicate-rotator check"
echo "  ouctl hop        # rotate the WARP /64 now (unlimited)"
echo "  ouctl fix        # consolidate + revive daemon + heal tunnel"
echo ""
echo "Close and reopen your terminal once so PATH picks up ~/.local/bin."
echo "The guard rotates on every quota wall — there is no hourly cap."
