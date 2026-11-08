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

pause_keeper(){ mkdir -p "$GUARD_DIR"; printf '%s' "$$" > "$PAUSE" 2>/dev/null; }
resume_keeper(){ rm -f "$PAUSE" 2>/dev/null; }
trap resume_keeper EXIT INT TERM HUP

cur_ip(){ curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null; }

# warp hands out cloudflare ranges. anything else means the tunnel is not up
# and the "new" address is your own ISP — never report that as a rotation.
is_warp_ip(){ case "${1:-}" in 104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) return 0;; *) return 1;; esac; }
warp_prefix(){
  # only the warp tunnel carries 2606:4700::/32. any other utun with a global
  # v6 (a second VPN, a corporate tunnel) would otherwise be mistaken for the
  # quota key and blacklist the wrong block forever.
  ifconfig 2>/dev/null \
    | awk '/^utun/{i=$1} /inet6 2606:4700:/{print $2}' \
    | head -1 | cut -d/ -f1 | awk -F: '{print $1":"$2":"$3":"$4}'
}


cur_device(){ wo registration show 2>/dev/null | awk '/^ID:/{print $2; exit}'; }

OLD=$(cur_ip)
OLD_DEV=$(cur_device)
OLD_PFX=$(warp_prefix)
echo "old egress: ${OLD:-?}  /64 ${OLD_PFX:-none}"

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

# "Connected" can appear before the utun actually carries traffic. wait for a
# real address, and give the tunnel one clean second chance before failing.
wait_egress(){
  local i ip
  for i in $(seq 1 30); do
    sleep 3
    wo status 2>/dev/null | head -1 | grep -q Connected || continue
    ip=$(cur_ip)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

rotate_once(){
  w disconnect
  wait_disconnected || true
  register_fresh || return 1
  w connect
  NIP=$(wait_egress) || {
    echo "  first connect carried no traffic — reconnecting once"
    w disconnect; sleep 2; w connect
    NIP=$(wait_egress) || NIP=""
  }
  return 0
}

pause_keeper
echo "-- rotating (keeper paused) --"
if ! rotate_once; then
  echo "-- registration failed: ${reg_new_err:-unknown} --"
  echo "-- disconnecting so direct egress wins --"
  w disconnect
  resume_keeper
  exit 1
fi
echo "new egress: ${NIP:-?}"

# four addresses exist in this pool, so landing back on the one you started
# from is common. take one more swing when that happens: a fresh identity
# either way, but a different address is what you actually asked for.
FIRST_DEV=$(cur_device)
if [ -n "$NIP" ] && [ "$NIP" = "$OLD" ] && is_warp_ip "$OLD" \
   && [ -n "$FIRST_DEV" ] && [ "$FIRST_DEV" != "$OLD_DEV" ]; then
  echo "  same address as before — one more rotation"
  rotate_once || true
  echo "new egress: ${NIP:-?}"
fi
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
if ! is_warp_ip "$NIP"; then
  echo "-- egress is not cloudflare ($NIP) — the tunnel did not come up; not a rotation --"
  w disconnect
  exit 1
fi
NEW_DEV=$(cur_device)
# cloudflare's free pool is four addresses. the quota follows the registration
# (device id), not the address, so a repeated ip with a new device id is still
# a fresh identity.
if [ -n "$NEW_DEV" ] && [ "$NEW_DEV" != "$OLD_DEV" ]; then
  echo "== FRESH IDENTITY ✓  device ${OLD_DEV:0:8}… → ${NEW_DEV:0:8}…  egress $NIP  /64 $(warp_prefix) =="
  echo "   re-send your message"
  exit 0
fi
if [ "$NIP" != "$OLD" ]; then
  echo "== new egress $NIP, but the device id did not change — run me again =="
  exit 1
fi
echo "== cloudflare handed back the same block and device — run me again =="
exit 1
