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
  elif [ -x "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" ]; then WARP="/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
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

# a plain `registration delete` then `registration new` is a race: the daemon
# re-creates or keeps the blob for a moment and `new` answers "Old registration
# is still around" five times in a row. delete, confirm it is actually gone,
# then register — and re-clear whenever the daemon hands the old one back.
reg_present(){ wo registration show 2>/dev/null | grep -qi "ID:"; }

wait_disconnected(){
  local i
  for i in $(seq 1 10); do
    wo status 2>/dev/null | head -1 | grep -q Disconnected && return 0
    sleep 1
  done
  return 1
}

clear_registration(){
  local i
  for i in 1 2 3 4 5; do
    w registration delete
    sleep 2
    reg_present || return 0
  done
  return 1
}

reg_new_err=""
register_fresh(){
  local i out
  clear_registration
  for i in 1 2 3 4 5; do
    out=$(sudo -n "$WARP" --accept-tos registration new 2>&1 \
          || sudo -n "$WARP" registration new 2>&1)
    rc=$?
    # success is the command's exit status. a fresh registration obviously
    # shows an ID afterwards — checking "no ID" here was the bug.
    if [ "$rc" -eq 0 ]; then return 0; fi
    reg_new_err=$(printf '%s' "$out" | tail -1)
    case "$out" in *"still around"*|*"already"*) clear_registration ;; esac
    sleep 3
  done
  return 1
}

pause_keeper
echo "-- rotating (keeper paused) --"
w disconnect
wait_disconnected || true
if register_fresh; then
  w connect
else
  echo "-- registration failed: ${reg_new_err:-unknown} --"
  echo "-- disconnecting so direct egress wins --"
  w disconnect
  resume_keeper
  exit 1
fi

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
