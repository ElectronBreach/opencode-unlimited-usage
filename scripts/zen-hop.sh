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

# the identity rule lives in one file, shared with the guard. a rotation is
# real when the egress /64 changes — not when the device id does.
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$SRC_DIR/zen-identity.sh" ]; then . "$SRC_DIR/zen-identity.sh"; fi

# the WARP window is a separate front-end from the root daemon. if it is open
# while the registration is deleted, it paints itself into the Zero Trust
# "Enroll your device" page and stays there after the tunnel is healthy again.
# put it away for the surgery and bring it back afterwards; the daemon never
# notices, and the stale page never gets drawn.
WARP_APP="/Applications/Cloudflare WARP.app"
gui_running(){ pgrep -f "$WARP_APP/Contents/MacOS/Cloudflare WARP" >/dev/null 2>&1; }
gui_pause(){ if gui_running; then GUI_WAS_UP=1; osascript -e 'tell application "Cloudflare WARP" to quit' >/dev/null 2>&1 || true; pkill -f "$WARP_APP/Contents/MacOS/Cloudflare WARP" >/dev/null 2>&1 || true; fi; }
gui_resume(){ [ "${GUI_WAS_UP:-0}" = "1" ] && { sleep 1; open -g -a "$WARP_APP" >/dev/null 2>&1 || open -a "$WARP_APP" >/dev/null 2>&1; GUI_WAS_UP=0; }; }

w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

# read-only diagnosis: what bucket are we on right now, and is it burnt.
if [ "${1:-}" = "--where" ] || [ "${1:-}" = "--dry-run" ]; then
  B=$(oui_bucket 2>/dev/null || true)
  printf 'bucket   %s\n' "${B:-none}"
  printf 'v6       %s\n' "$(oui_probe6 2>/dev/null || true)"
  printf 'v4       %s\n' "$(oui_probe4 2>/dev/null || true)"
  printf 'device   %s\n' "$(wo registration show 2>/dev/null | awk '/^ID:/{print $2; exit}')"
  printf 'state    %s\n' "$(oui_state_get prefix)"
  if [ -n "$B" ] && oui_bl_has "$B"; then printf 'burnt    yes\n'; else printf 'burnt    no\n'; fi
  printf 'blacklist\n'
  oui_bl_list | sed 's/^/         /'
  exit 0
fi

pause_keeper(){ mkdir -p "$GUARD_DIR"; printf '%s' "$$" > "$PAUSE" 2>/dev/null; }
resume_keeper(){ rm -f "$PAUSE" 2>/dev/null; }

ROT_LOCK="$GUARD_DIR/rotate.lock"
rot_acquire(){
  local i age
  for i in $(seq 1 150); do
    mkdir "$ROT_LOCK" 2>/dev/null && return 0
    age=$(( $(date +%s) - $(stat -f %m "$ROT_LOCK" 2>/dev/null || echo 0) ))
    [ "$age" -gt 300 ] && rm -rf "$ROT_LOCK" 2>/dev/null
    sleep 2
  done
  return 1
}
rot_release(){ rmdir "$ROT_LOCK" 2>/dev/null; }
cleanup(){ resume_keeper; rot_release; }
trap cleanup EXIT INT TERM HUP

cur_ip(){ curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null; }
# the utun address (2606:4700:110::) is the tunnel's inside leg. what the
# server sees is cloudflare's egress (2a09:bac5:...::/64), and that is the
# value the quota is keyed on. measure the real one.
seen4(){ curl -4 -sS -m 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}'; }
seen6(){ curl -6 -sS -m 8 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null | awk -F= '/^ip=/{print $2; exit}'; }
seen6_prefix(){ local a; a=$(seen6); [ -n "$a" ] || return 1; printf '%s' "$a" | awk -F: '{print $1":"$2":"$3":"$4}'; }

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
OLD_PFX=$(seen6_prefix 2>/dev/null || true)
[ -n "$OLD_PFX" ] || OLD_PFX=$(warp_prefix)
OLD_SEEN4=$(seen4 2>/dev/null || true)
# the bucket is what the quota is actually keyed on. probes first, cached
# state second, utun prefix last (a tunnel with no egress path yet).
OLD_BUCKET=$(oui_bucket 2>/dev/null || true)
[ -n "$OLD_BUCKET" ] || OLD_BUCKET="$OLD_PFX"
echo "old egress: ${OLD:-?}  /64 ${OLD_PFX:-none}  bucket ${OLD_BUCKET:-?}"

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
    sleep 1
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
    # back off: hammering registration while cloudflare is unhappy is how you
    # get rate-limited, and a rate limit looks exactly like a dead account
    sleep $(( i * 3 ))
  done
  return 1
}

# "Connected" can appear before the utun actually carries traffic. wait for a
# real address, and give the tunnel one clean second chance before failing.
wait_egress(){
  local i ip
  for i in $(seq 1 20); do
    sleep 1
    wo status 2>/dev/null | head -1 | grep -q Connected || continue
    ip=$(cur_ip)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

rotate_once(){
  gui_pause
  w disconnect
  wait_disconnected || true
  register_fresh || return 1
  w connect
  NIP=$(wait_egress) || {
    echo "  first connect carried no traffic — reconnecting once"
    w disconnect; sleep 2; w connect
    NIP=$(wait_egress) || NIP=""
  }
  gui_resume
  return 0
}

pause_keeper
if ! rot_acquire; then
  echo "another rotation has owned the tunnel for 5 minutes — not stacking a second one"
  exit 1
fi
echo "-- rotating (keeper paused) --"
if ! rotate_once; then
  echo "-- registration failed: ${reg_new_err:-unknown} --"
  echo "-- disconnecting so direct egress wins --"
  w disconnect
  resume_keeper
  exit 1
fi
echo "new egress: ${NIP:-?}"

# ---- verdict --------------------------------------------------------------
# the bucket is the egress /64 the server keys the quota on. four v4
# addresses and two edges live in that pool, so landing back on the block you
# started from is common — and a fresh device id sitting on the same /64 is
# NOT a new identity, however clean the registration looks. that was the bug:
# the old check accepted "device id changed" and printed a green tick while
# the quota key had not moved at all.
NB=$(oui_bucket 2>/dev/null || true)
NEW_DEV=$(cur_device)

if [ -n "$NB" ] && { [ "$NB" = "$OLD_BUCKET" ] || oui_bl_has "$NB"; }; then
  # a burned block is no better than the one we just left — both are walls we
  # have already hit. b40:8 measured a wall at 01:05 and another three minutes
  # after we landed back on it at 10:05, so reuse is a guaranteed second wall.
  if [ "$NB" = "$OLD_BUCKET" ]; then
    echo "  same /64 ($NB) as before — one more rotation"
  else
    echo "  landed on a burned /64 ($NB) — one more rotation"
  fi
  rotate_once || true
  NB=$(oui_bucket 2>/dev/null || true)
  NEW_DEV=$(cur_device)
fi
resume_keeper

if [ -z "$NB" ]; then
  echo "-- tunnel connected but no cloudflare egress — disconnecting, keeper repairs --"
  w disconnect
  exit 1
fi

if [ "$NB" = "$OLD_BUCKET" ]; then
  echo "== same bucket ($NB) — cloudflare did not hand out a different /64 =="
  echo "== the registration moved, the quota key did not. run me again =="
  exit 1
fi
if oui_bl_has "$NB"; then
  echo "== burned bucket ($NB) — that block already took a wall, it is not a fresh identity =="
  echo "== try again: cloudflare hands out a different /64 on the next registration =="
  exit 1
fi

# real rotation. burn the old bucket, credit the new one, publish the state
# the HUD and doctor read.
oui_bl_add "$OLD_BUCKET" 2>/dev/null || true
oui_ledger "$OLD_BUCKET" wall 2>/dev/null || true
oui_ledger "$NB" hop 2>/dev/null || true

PFX_NOW="$NB"
SEEN6_NOW=$(seen6 2>/dev/null || true)
SEEN4_NOW=$(seen4 2>/dev/null || true)
[ -n "$SEEN4_NOW" ] || SEEN4_NOW="$NIP"
if [ -f "$GUARD_DIR/state.json" ]; then
  python3 - "$GUARD_DIR/state.json" "$SEEN4_NOW" "$PFX_NOW" "$NEW_DEV" "$SEEN6_NOW" <<'PY' 2>/dev/null
import json,sys,os,time
p,ip,pfx,dev,s6 = sys.argv[1:6]
try: d=json.load(open(p))
except: d={}
d["current"]=ip
d["prefix"]=pfx
d["device"]=dev
d["seen6"]=s6
d["last_hop"]=int(time.time())
try: h=int(d.get("hops") or 0)
except: h=0
d["hops"]=h+1
t=p+".tmp"
with open(t,"w") as f: json.dump(d,f,separators=(",",":"))
os.replace(t,p)
PY
fi
echo "== FRESH BUCKET ✓  ${OLD_BUCKET:-?} → ${NB}  device ${OLD_DEV:0:8}… → ${NEW_DEV:0:8}… =="
echo "   egress ${SEEN4_NOW:-$NIP}"
echo "   re-send your message"
exit 0
