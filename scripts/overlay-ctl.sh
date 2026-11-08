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
#   opencode-unlimited-overlay close      quit the HUD
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

show(){
  ctx
  if running; then
    printf 'expand\n' > "$CMD"
  else
    open -g "$APP" --args --session-dir "${OUC_SESSION_DIR:-$PWD}"
  fi
}

action="${1:-show}"
case "$action" in
  show)     show ;;
  close)    printf 'close\n' > "$CMD" ;;
  hop|doctor|toggle|expand|collapse|reload)
            ctx
            running || open -g "$APP" --args --session-dir "${OUC_SESSION_DIR:-$PWD}"
            sleep 0.4
            printf '%s\n' "$action" > "$CMD" ;;
  *)        echo "usage: $(basename "$0") [show|toggle|collapse|expand|hop|doctor|reload|close]" >&2; exit 2 ;;
esac
