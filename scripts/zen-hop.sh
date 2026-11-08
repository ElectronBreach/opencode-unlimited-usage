#!/bin/bash
# zen hop — manual identity rotation (macOS). deletes the current warp
# registration, registers fresh, reconnects. you land on a new egress.
#
# the keeper is paused during the hop via a marker file — otherwise its tick
# races us and "helpfully" repairs the tunnel mid-surgery. the leak guard is
# flushed by the keeper the moment the tunnel drops, so there is no window
# where rules block a dead tunnel.
set -u

DEST="$HOME/.local/share/opencode-unlimited"
GUARD_DIR="$DEST/guard"
PAUSE="$GUARD_DIR/keeper.pause"

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/local/bin/warp-cli ]; then WARP=/usr/local/bin/warp-cli
  elif [ -x /opt/homebrew/bin/warp-cli ]; then WARP=/opt/homebrew/bin/warp-cli
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }

w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

pause_keeper(){ mkdir -p "$GUARD_DIR"; : > "$PAUSE" 2>/dev/null; }
resume_keeper(){ rm -f "$PAUSE" 2>/dev/null; }
trap resume_keeper EXIT INT TERM HUP

cur_ip(){ curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null; }

OLD=$(cur_ip)
echo "old egress: ${OLD:-?}"

pause_keeper
echo "-- rotating (keeper paused) --"
w disconnect
w registration delete
NEW=0
for i in 1 2 3 4 5; do
  w registration new && { NEW=1; break; }
  echo "  attempt $i failed"; sleep 8
done
if [ "$NEW" != 1 ]; then
  echo "-- registration failed — disconnecting so direct egress wins --"
  w disconnect
  resume_keeper
  exit 1
fi
w mode warp
w connect

for i in $(seq 1 20); do
  sleep 3
  wo status | head -1 | grep -q Connected && break
done

NIP=$(cur_ip)
echo "new egress: ${NIP:-?}"
resume_keeper

# record the new identity so doctor/guard state stays truthful
if [ -n "$NIP" ] && [ -f "$GUARD_DIR/state.json" ]; then
  python3 - "$GUARD_DIR/state.json" "$NIP" <<'PY' 2>/dev/null
import json,sys
p,v = sys.argv[1], sys.argv[2]
try: d=json.load(open(p))
except: d={}
d["current"]=v
d["last_hop"]=int(__import__("time").time())
json.dump(d,open(p,"w"),separators=(",",":"))
PY
fi

if [ -z "$NIP" ]; then
  echo "-- tunnel connected but no egress — disconnect + let keeper repair --"
  w disconnect
  exit 1
fi
if [ "$NIP" != "$OLD" ]; then
  echo "== FRESH IDENTITY ✓ — re-send your message =="
  exit 0
fi
echo "== cloudflare handed back the same block — run me again =="
exit 1
