#!/bin/bash
# opencode-unlimited — macOS installer (launchd, unlimited rotation)
#
# The Linux scripts in this repo are systemd. macOS has no systemd and no
# `unshare -rm`, so a straight port does not work. This installs the macOS
# equivalent: one launchd rotator (ocul), one global rotation lock shared by
# every stack, GUI parking so the Zero Trust enrollment page never appears,
# daemon revival when WARP's socket vanishes, and NO hourly rotation cap.
#
# Requires: Cloudflare WARP.app installed, python3, warp-cli on PATH.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/share/ocu-lane"
BIN="$HOME/.local/bin"
WARP_CLI="$(command -v warp-cli || true)"
[ -x "/usr/local/bin/warp-cli" ] && WARP_CLI="/usr/local/bin/warp-cli"
[ -x "/opt/homebrew/bin/warp-cli" ] && WARP_CLI="/opt/homebrew/bin/warp-cli"

say(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

say "opencode-unlimited — macOS"

# ---- prerequisites --------------------------------------------------------
if [ -z "$WARP_CLI" ]; then
  bad "warp-cli not found — install Cloudflare WARP.app first"
  exit 1
fi
ok "warp-cli: $WARP_CLI"

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — install it (brew install python@3.13)"
  exit 1
fi
ok "python3: $(command -v python3)"

if [ ! -d "/Applications/Cloudflare WARP.app" ]; then
  bad "/Applications/Cloudflare WARP.app missing"
  exit 1
fi

# ---- install the rotator --------------------------------------------------
say "installing rotator"
mkdir -p "$DEST" "$BIN"
install -m 0755 "$REPO_DIR/ocul.py" "$DEST/ocul.py"
install -m 0755 "$REPO_DIR/ouctl"  "$BIN/ouctl"
ok "ocul.py  -> $DEST/ocul.py"
ok "ouctl    -> $BIN/ouctl"

# ocul install writes ~/.local/bin/ocul and the ai.ocul.guard launchd agent
python3 "$DEST/ocul.py" install
ok "launchd agent ai.ocul.guard loaded"

# ---- one rotator only -----------------------------------------------------
say "consolidating (one rotator, one lock)"
"$BIN/ouctl" consolidate || true

# ---- wire the shell helpers ----------------------------------------------
# make `hop` / `doctor` reachable under the same names the repo uses
ln -sf "$BIN/ouctl" "$BIN/hop" 2>/dev/null || true
ln -sf "$BIN/ocul"  "$BIN/ocul-doctor" 2>/dev/null || true

say ""
say "done. next:"
echo "  ouctl doctor        # health + duplicate-rotator check"
echo "  ouctl hop           # rotate the WARP /64 now (unlimited)"
echo "  ouctl fix           # consolidate + revive daemon + heal tunnel"
echo ""
echo "the guard rotates automatically on every quota wall. there is no hourly"
echo "cap: a fresh registration = a fresh egress /64. close and reopen your"
echo "terminal once so PATH picks up ~/.local/bin."
