#!/bin/bash
# zen guard — the self-healing part. watches opencode's own error log for
# the free-usage wall and rotates your /64 automatically.
#
# opencode writes its errors to ~/.local/share/opencode/log/opencode.log —
# we tail it with a byte offset (only ever read new bytes). the moment a
# quota error shows up:
#   1. current /64 goes on the lifetime blacklist (never reused again)
#   2. keeper pauses (its 45s tick would race the rotation)
#   3. warp re-registers → fresh /64 → keeper resumes
#   4. if cloudflare hands back a blacklisted block, try again (up to 8)
#   5. if literally everything comes back burned, recycle the oldest —
#      these buckets reset around midnight anyway
# then you, the human, just re-send your message and the wall is gone.
set -u

LOGF="$HOME/.local/share/opencode/log/opencode.log"
STATE_DIR="$HOME/.local/share/opencode-unlimited/guard"
STATE="$STATE_DIR/state.json"
GUARD_LOG="$STATE_DIR/guard.log"

# warp binary: service env → PATH → common fallbacks. probe with/without
# --accept-tos (shimmed boxes pass it twice = dead CLI).
WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/bin/warp-cli ]; then WARP=/usr/bin/warp-cli
  elif [ -x "$HOME/.local/bin/warp-cli" ]; then WARP="$HOME/.local/bin/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }
KEEPER="${OUC_KEEPER_UNIT:-opencode-unlimited-keeper}"

COOLDOWN=75        # seconds between rotations (a rotation takes ~15s)
MAX_HOP_TRIES=8
BLACKLIST_MAX=200  # lifetime blacklist cap — burnt /64s never come back

mkdir -p "$STATE_DIR"

svc(){ sudo -n systemctl "$@" >/dev/null 2>&1 || sudo systemctl "$@" >/dev/null 2>&1; }
w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

glog(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$GUARD_LOG"; }

state_get(){ python3 -c "
import json
try: d=json.load(open('$STATE'))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
print(d.get('$1',''))" 2>/dev/null; }

state_set(){ python3 -c "
import json,sys
try: d=json.load(open('$STATE'))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
d['$1']=sys.argv[1]
json.dump(d,open('$STATE','w'))" "$2" 2>/dev/null; }

cur_v6(){ timeout 10 curl -s -m 8 https://api64.ipify.org 2>/dev/null; }

# blacklist entries are /64-normalized (first 4 groups) — same mohalla,
# same bucket. comparing full addresses was the original bug: the same
# block came back with a different interface-id and sailed right through.
blacklist_add(){
  python3 - "$1" <<'PY' 2>/dev/null
import json,sys,os
def m64(a): return ":".join(a.split(":")[:4])
p=os.path.expanduser("~/.local/share/opencode-unlimited/guard/state.json")
try: d=json.load(open(p))
except: d={"blacklist":[],"offset":0,"last_hop":0,"hops":0,"current":""}
m=m64(sys.argv[1])
d["blacklist"]=[x for x in d["blacklist"] if x and m64(x)!=m]+[m]
d["blacklist"]=d["blacklist"][-200:]
json.dump(d,open(p,"w"))
PY
}

is_burnt(){
  python3 - "$1" <<'PY' 2>/dev/null
import json,sys,os
def m64(a): return ":".join(a.split(":")[:4])
try: d=json.load(open(os.path.expanduser("~/.local/share/opencode-unlimited/guard/state.json")))
except: sys.exit(1)
m=m64(sys.argv[1])
sys.exit(0 if any(x and m64(x)==m for x in d.get("blacklist",[])) else 1)
PY
}

hop_once(){
  # one keeper-safe registration cycle. prints the new /64 or empty.
  svc stop "$KEEPER"
  w disconnect
  w registration delete
  local ok=0 i
  for i in 1 2 3; do
    w registration new && { ok=1; break; }
    sleep 6
  done
  w mode warp
  w connect
  svc start "$KEEPER"
  [ "$ok" = 1 ] || { echo ""; return; }
  local V=""
  for i in $(seq 1 12); do
    sleep 3
    V=$(cur_v6)
    [ -n "$V" ] && break
    V=""
  done
  echo "$V"
}

# fresh state: start reading from the end of the current log
if [ ! -f "$STATE" ]; then
  OFF=0; [ -f "$LOGF" ] && OFF=$(wc -c < "$LOGF")
  printf '{"blacklist":[],"offset":%s,"last_hop":0,"hops":0,"current":""}' "$OFF" > "$STATE"
fi

glog "zen-guard up (cooldown ${COOLDOWN}s, blacklist lifetime)"

while true; do
  sleep 20

  # ---- wall sniff (new bytes only) ----
  [ -f "$LOGF" ] || continue
  SIZE=$(wc -c < "$LOGF" 2>/dev/null || echo 0)
  OFF=$(state_get offset); OFF=${OFF:-0}
  NEWBYTES=$((SIZE - OFF))
  WALL=0
  if [ "$NEWBYTES" -gt 0 ] && [ "$NEWBYTES" -lt 50000000 ]; then
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | grep -aq "QuotaExceeded"; then
      WALL=1
    fi
  fi
  state_set offset "$SIZE"

  NOW=$(date +%s)
  LASTHOP=$(state_get last_hop); LASTHOP=${LASTHOP:-0}
  AGE=$((NOW - LASTHOP))

  if [ "$WALL" = 1 ] && [ "$AGE" -ge "$COOLDOWN" ]; then
    OLD=$(cur_v6)
    glog "wall detected — rotating (was: $OLD)"
    blacklist_add "$OLD"
    NEW=""
    TRY=0
    while [ "$TRY" -lt "$MAX_HOP_TRIES" ]; do
      TRY=$((TRY + 1))
      V=$(hop_once)
      if [ -z "$V" ]; then glog "try $TRY: tunnel repair failed"; continue; fi
      if is_burnt "$V"; then glog "try $TRY: cloudflare returned a blacklisted /64 ($V) — again"; continue; fi
      NEW="$V"; break
    done
    # every block burned → recycle the oldest (they reset around midnight)
    if [ -z "$NEW" ]; then
      glog "everything blacklisted — recycling oldest block"
      V=$(hop_once)
      [ -n "$V" ] && NEW="$V"
    fi
    if [ -n "$NEW" ]; then
      state_set last_hop "$NOW"
      state_set current "$NEW"
      H=$(state_get hops); H=${H:-0}; H=$((H + 1))
      state_set hops "$H"
      glog "rotated #$H: $OLD → $NEW ✓"
    else
      state_set last_hop "$NOW"
      glog "rotation failed — keeper will keep the tunnel alive, retrying next tick"
    fi
  elif [ "$WALL" = 1 ]; then
    glog "wall seen but in cooldown (${AGE}s < ${COOLDOWN}s) — waiting"
  fi
done
