#!/bin/bash
# zen guard — the self-healing part (macOS port). watches opencode's own
# error log for the free-usage wall and rotates your egress automatically.
#
# Hard rules learned from this machine:
#   * never rotate when warp is missing / dangling / disconnected
#   * never blacklist direct (non-warp) egress
#   * after a rotation, verify DNS — repair it if broken
set -u

LOGF="$HOME/.local/share/opencode/log/opencode.log"
DEST="$HOME/.local/share/opencode-unlimited"
STATE_DIR="$DEST/guard"
STATE="$STATE_DIR/state.json"
GUARD_LOG="$STATE_DIR/guard.log"
PAUSE="$STATE_DIR/keeper.pause"
BASELINE="$STATE_DIR/dns-baseline.txt"

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ] || [ ! -s "$WARP" ] || ! "$WARP" --version >/dev/null 2>&1; then
  WARP=""
  for c in "$(command -v warp-cli 2>/dev/null)" /usr/local/bin/warp-cli /opt/homebrew/bin/warp-cli "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"; do
    [ -n "$c" ] && [ -x "$c" ] && [ -s "$c" ] || continue
    "$c" --version >/dev/null 2>&1 || continue
    WARP="$c"; break
  done
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }

COOLDOWN=75
MAX_HOP_TRIES=8
WALL_RE="QuotaExceeded|Free usage limit reached|usage limit reached|FreeUsageLimitError|FreeUsageLimit|rate limit exceeded|too many requests"

mkdir -p "$STATE_DIR"

w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

glog(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$GUARD_LOG"; }

pause_keeper(){ : > "$PAUSE" 2>/dev/null; }
resume_keeper(){ rm -f "$PAUSE" 2>/dev/null; }
trap resume_keeper EXIT INT TERM HUP

state_get(){ python3 -c "
import json
try: d=json.load(open('$STATE'))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
print(d.get('$1',''))" 2>/dev/null; }

state_set(){ python3 -c "
import json,sys
try: d=json.load(open('$STATE'))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
v=sys.argv[1]
v=v.strip()
d['$1']=int(v) if v.isdigit() else v
json.dump(d,open('$STATE','w'))" "$2" 2>/dev/null; }

cur_ip(){ curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null; }

# warp hands out cloudflare ranges; anything else is direct ISP egress and
# must never be blacklisted or rotated
is_warp_ip(){ case "${1:-}" in 104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) return 0;; *) return 1;; esac; }

bl_norm(){ python3 -c "
import sys
a=sys.argv[1]
print(':'.join(a.split(':')[:4]) if ':' in a else a)" "$1" 2>/dev/null; }

blacklist_add(){
  python3 - "$STATE" "$1" <<'PY' 2>/dev/null
import json,sys
p, a = sys.argv[1], sys.argv[2]
def n(x): return ":".join(x.split(":")[:4]) if ":" in x else x
try: d=json.load(open(p))
except: d={"blacklist":[],"offset":0,"last_hop":0,"hops":0,"current":""}
m=n(a)
d["blacklist"]=[x for x in d.get("blacklist",[]) if x and n(x)!=m]+[m]
d["blacklist"]=d["blacklist"][-200:]
json.dump(d,open(p,"w"))
PY
}

is_burnt(){
  python3 - "$STATE" "$1" <<'PY' 2>/dev/null
import json,sys
p, a = sys.argv[1], sys.argv[2]
def n(x): return ":".join(x.split(":")[:4]) if ":" in x else x
try: d=json.load(open(p))
except: sys.exit(1)
m=n(a)
sys.exit(0 if any(x and n(x)==m for x in d.get("blacklist",[])) else 1)
PY
}

dns_ok(){ [ -n "$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null)" ]; }

restore_dns(){
  local svc servers restored=0
  if [ -f "$BASELINE" ]; then
    while IFS=$'\t' read -r svc servers; do
      [ -n "$svc" ] || continue
      networksetup -listallnetworkservices 2>/dev/null | grep -qx "$svc" || continue
      if [ -z "$servers" ] || [ "$servers" = "Empty" ]; then
        networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 && restored=1
      else
        # shellcheck disable=SC2086
        networksetup -setdnsservers "$svc" $servers >/dev/null 2>&1 && restored=1
      fi
    done < "$BASELINE"
  fi
  if [ "$restored" = 0 ]; then
    svc=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' | head -1)
    [ -n "$svc" ] && networksetup -setdnsservers "$svc" 1.1.1.1 8.8.8.8 >/dev/null 2>&1
  fi
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
  glog "dns: baseline restored + cache flushed"
}

hop_once(){
  pause_keeper
  w disconnect
  w registration delete
  local ok=0 i
  for i in 1 2 3; do
    w registration new && { ok=1; break; }
    sleep 6
  done
  w connect
  resume_keeper
  [ "$ok" = 1 ] || { echo ""; return; }
  local V=""
  for i in $(seq 1 12); do
    sleep 3
    V=$(cur_ip)
    [ -n "$V" ] && break
    V=""
  done
  echo "$V"
}

if [ ! -f "$STATE" ]; then
  OFF=0; [ -f "$LOGF" ] && OFF=$(wc -c < "$LOGF")
  printf '{"blacklist":[],"offset":%s,"last_hop":0,"hops":0,"current":""}' "$OFF" > "$STATE"
fi

glog "zen-guard up (cooldown ${COOLDOWN}s, macOS, warp=$WARP)"

while true; do
  sleep 20

  [ -f "$LOGF" ] || continue
  SIZE=$(wc -c < "$LOGF" 2>/dev/null | tr -d ' ' || echo 0); SIZE=${SIZE:-0}
  OFF=$(state_get offset); OFF=${OFF:-0}
  case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac
  [ "$SIZE" -lt "$OFF" ] && OFF=0
  NEWBYTES=$((SIZE - OFF))
  WALL=0
  if [ "$NEWBYTES" -gt 0 ] && [ "$NEWBYTES" -lt 50000000 ]; then
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | grep -aqiE "$WALL_RE"; then WALL=1; fi
  fi
  state_set offset "$SIZE"

  NOW=$(date +%s)
  LASTHOP=$(state_get last_hop); LASTHOP=${LASTHOP:-0}
  case "$LASTHOP" in ''|*[!0-9]*) LASTHOP=0 ;; esac
  AGE=$((NOW - LASTHOP))

  [ "$WALL" = 1 ] || continue

  if [ "$AGE" -lt "$COOLDOWN" ]; then
    glog "wall seen but in cooldown (${AGE}s < ${COOLDOWN}s) — waiting"
    continue
  fi

  # warp must actually be usable, or a rotation would just wreck the network
  if ! wo status 2>/dev/null | head -1 | grep -q Connected; then
    glog "wall seen but warp is not connected — not rotating (no network surgery)"
    state_set last_hop "$NOW"
    continue
  fi

  OLD=$(cur_ip)
  glog "wall detected — rotating (was: ${OLD:-?})"
  [ -n "$OLD" ] && is_warp_ip "$OLD" && blacklist_add "$OLD"

  NEW=""
  TRY=0
  while [ "$TRY" -lt "$MAX_HOP_TRIES" ]; do
    TRY=$((TRY + 1))
    V=$(hop_once)
    if [ -z "$V" ]; then glog "try $TRY: tunnel repair failed"; continue; fi
    if is_burnt "$V"; then glog "try $TRY: cloudflare returned a blacklisted block ($V) — again"; continue; fi
    NEW="$V"; break
  done

  # upstream parity: when every block is burnt, recycle the oldest — these
  # buckets reset around midnight anyway
  if [ -z "$NEW" ]; then
    glog "every block blacklisted — recycling oldest block"
    V=$(hop_once)
    [ -n "$V" ] && NEW="$V"
  fi
  if [ -z "$NEW" ]; then
    glog "rotation failed — wall is likely account-side, not ip-side; keeping the tunnel"
  fi

  if [ -n "$NEW" ]; then
    state_set last_hop "$NOW"
    state_set current "$NEW"
    H=$(state_get hops); H=${H:-0}; H=$((H + 1))
    state_set hops "$H"
    glog "rotated #$H: ${OLD:-?} → $NEW ✓"
    if ! dns_ok; then
      glog "dns broken after rotation — repairing"
      restore_dns
      sleep 2
      if ! dns_ok; then
        glog "dns still broken — disconnecting warp so direct egress wins"
        w disconnect
        restore_dns
      fi
    fi
  else
    state_set last_hop "$NOW"
    glog "rotation failed — keeper keeps the tunnel alive, retrying next tick"
  fi
done
