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

COOLDOWN=30
MAX_HOP_TRIES=8
WALL_RE="QuotaExceeded|Free usage limit reached|usage limit reached|FreeUsageLimitError|FreeUsageLimit|rate limit exceeded|too many requests"

mkdir -p "$STATE_DIR"

w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

glog(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$GUARD_LOG"; }

pause_keeper(){ mkdir -p "$STATE_DIR"; printf '%s' "$$" > "$PAUSE" 2>/dev/null; }

# one rotation at a time across the guard AND the manual hop. two rotations
# interleaving delete/register on the same daemon is how a tunnel ends up
# "Connected" with no route.
ROT_LOCK="$STATE_DIR/rotate.lock"
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
trim_log(){
  local f="$1" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt 524288 ] || return 0
  tail -n 400 "$f" > "$f.trim" 2>/dev/null && mv "$f.trim" "$f" 2>/dev/null
}
# "Model unavailable" is the CLI's local verdict: its Console provider could
# not fetch the model list for this credential. if the network is fine now —
# which a 200 from the same endpoint proves — nudge opencode to reload its
# config, which re-runs provider.updated and repopulates the model list.
RESCUE_STAMP="$STATE_DIR/.provider-rescue"
rescue_provider(){
  local now last key code cfg
  now=$(date +%s)
  last=$(cat "$RESCUE_STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge 60 ] || return 0
  printf '%s' "$now" > "$RESCUE_STAMP" 2>/dev/null
  key=$(sqlite3 -readonly "$HOME/.local/share/opencode/opencode.db" \
          "select value from credential where integration_id='opencode' and active=1 limit 1;" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")' 2>/dev/null)
  code=$(curl -s -o /dev/null --connect-timeout 4 --max-time 12 \
          -H "Authorization: Bearer $key" -w '%{http_code}' \
          https://opencode.ai/inference/openai/v1/models 2>/dev/null)
  case "$code" in
    2*) ;;
    *) glog "model unavailable — console answered '${code:-nothing}', leaving it alone"; return 0 ;;
  esac
  cfg="$HOME/.config/opencode/opencode.json"
  if [ -f "$cfg" ]; then
    touch "$cfg" 2>/dev/null && glog "model unavailable while the console answers 200 — forced a provider reload"
  fi
  return 0
}

resume_keeper(){ rm -f "$PAUSE" 2>/dev/null; }
trap resume_keeper EXIT INT TERM HUP

state_get(){ python3 -c "
import json
try: d=json.load(open('$STATE'))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
print(d.get('$1',''))" 2>/dev/null; }

# atomic: kill -9 mid-write used to truncate state.json, which reset offset to 0
# and made the guard re-read the whole log and rotate on an old wall.
state_set(){ python3 -c "
import json,sys,os
p='$STATE'
try: d=json.load(open(p))
except: d={'blacklist':[],'offset':0,'last_hop':0,'hops':0,'current':''}
v=sys.argv[1].strip()
d['$1']=int(v) if v.isdigit() else v
t=p+'.tmp'
with open(t,'w') as f: json.dump(d,f)
os.replace(t,p)" "$2" 2>/dev/null; }

cur_ip(){ curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null; }
cur_device(){ wo registration show 2>/dev/null | awk '/^ID:/{print $2; exit}'; }
seen4(){ curl -4 -sS -m 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}'; }
seen6(){ curl -6 -sS -m 8 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null | awk -F= '/^ip=/{print $2; exit}'; }
seen6_prefix(){ local a; a=$(seen6); [ -n "$a" ] || return 1; printf '%s' "$a" | awk -F: '{print $1":"$2":"$3":"$4}'; }
warp_prefix(){
  # only the warp tunnel carries 2606:4700::/32. any other utun with a global
  # v6 (a second VPN, a corporate tunnel) would otherwise be mistaken for the
  # quota key and blacklist the wrong block forever.
  ifconfig 2>/dev/null \
    | awk '/^utun/{i=$1} /inet6 2606:4700:/{print $2}' \
    | head -1 | cut -d/ -f1 | awk -F: '{print $1":"$2":"$3":"$4}'
}


# warp hands out cloudflare ranges; anything else is direct ISP egress and
# must never be blacklisted or rotated
is_warp_ip(){ case "${1:-}" in 104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) return 0;; *) return 1;; esac; }

# ---- identity rule, shared with the manual hop -----------------------------
# a rotation is real when the egress /64 changes. device id, v4 address and
# edge are evidence about how we got there, never the quota key.
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$SRC_DIR/zen-identity.sh" ]; then . "$SRC_DIR/zen-identity.sh"; fi

bl_norm(){ oui64 "${1:-}"; }

# only egress blocks are stored. the old writer happily pushed the tunnel's
# inside leg (2606:4700:110:*) and bare v4 duplicates into this list, where
# they occupied slots forever and never matched anything.
blacklist_add(){ oui_bl_add "${1:-}"; }

is_burnt(){ oui_bl_has "${1:-}"; }


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

reg_present(){ wo registration show 2>/dev/null | grep -qi "ID:"; }

clear_registration(){
  local i
  for i in 1 2 3 4 5; do
    w registration delete
    sleep 1
    reg_present || return 0
  done
  return 1
}

# the tunnel does not come up the instant `connect` returns. probing once and
# declaring "no egress" spends a whole registration on a tunnel that was still
# settling — six of those in a row is what the log called six failures.
wait_bucket(){
  local i b
  for i in $(seq 1 "${1:-12}"); do
    b=$(oui_bucket 2>/dev/null || true)
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    sleep 1
  done
  return 1
}

# a rotation that never returns is a dead guard. bound it hard.
hop_with_timeout(){
  local out p i
  out=$(mktemp /tmp/ouc-hop.XXXXXX 2>/dev/null) || { hop_once; return; }
  ( hop_once > "$out" 2>/dev/null ) &
  p=$!
  i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 90 ]; then
      glog "rotation exceeded 180s — killing it and keeping the tunnel"
      kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null
      break
    fi
    sleep 2
  done
  wait "$p" 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$out"
}

hop_once(){
  pause_keeper
  w disconnect
  clear_registration
  local ok=0 i
  for i in 1 2 3; do
    if ! reg_present && w registration new; then ok=1; break; fi
    clear_registration
    sleep 2
  done
  w connect
  resume_keeper
  [ "$ok" = 1 ] || { echo ""; return; }
  local V=""
  for i in $(seq 1 20); do
    sleep 1
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

# one-time repair of a blacklist written before the identity rule existed.
# it holds the tunnel's inside leg and bare v4 duplicates on this box, and
# neither can ever match a bucket.
if [ -n "$(command -v oui_bl_migrate)" ]; then
  MIG=$(oui_bl_migrate 2>/dev/null || true)
  [ -n "$MIG" ] && glog "blacklist $MIG"
fi

while true; do
  rot_release
  trim_log "$GUARD_LOG"
  sleep 6

  [ -f "$LOGF" ] || continue
  SIZE=$(wc -c < "$LOGF" 2>/dev/null | tr -d ' ' || echo 0); SIZE=${SIZE:-0}
  OFF=$(state_get offset); OFF=${OFF:-0}
  case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac
  [ "$SIZE" -lt "$OFF" ] && OFF=0
  NEWBYTES=$((SIZE - OFF))
  WALL=0
  MODELDOWN=0
  if [ "$NEWBYTES" -gt 0 ] && [ "$NEWBYTES" -lt 50000000 ]; then
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | grep -aqiE "$WALL_RE"; then WALL=1; fi
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | head -c "$NEWBYTES" | grep -aq "ModelUnavailableError"; then MODELDOWN=1; fi
  fi
  # a rotation already owns the tunnel (manual hop or keeper surgery). do not
  # advance the offset: the wall is still ours to act on next tick.
  if [ -f "$PAUSE" ]; then
    PPID_OWNER=$(tr -dc '0-9' < "$PAUSE" 2>/dev/null)
    if [ -n "$PPID_OWNER" ] && ! kill -0 "$PPID_OWNER" 2>/dev/null; then
      glog "rotation marker was orphaned (pid $PPID_OWNER gone) — clearing it"
      rm -f "$PAUSE" 2>/dev/null
    else
      [ "$WALL" = 1 ] && glog "wall seen while a rotation owns the tunnel — holding it for the next tick"
      continue
    fi
  fi
  state_set offset "$SIZE"

  [ "$MODELDOWN" = 1 ] && rescue_provider

  NOW=$(date +%s)
  LASTHOP=$(state_get last_hop); LASTHOP=${LASTHOP:-0}
  case "$LASTHOP" in ''|*[!0-9]*) LASTHOP=0 ;; esac
  AGE=$((NOW - LASTHOP))

  [ "$WALL" = 1 ] || continue

  # jitter the cooldown so repeated walls do not align to the same tick
  COOLDOWN_J=$(( COOLDOWN + (RANDOM % 10) ))
  # a wall that lands within three minutes of a rotation means the fresh
  # bucket did not help — it is the account or a cached session, not the ip.
  # burning another registration on a 30 s cadence just empties the pool of
  # fresh /64s for the moment you actually need one.
  if [ "$AGE" -lt 180 ]; then COOLDOWN_J=60; fi

  # count walls that arrive while the identity is still brand new. one is bad
  # luck, three in a row is the account — and no amount of /64s fixes that.
  if [ "$AGE" -lt 60 ]; then
    FW=$(state_get fastwalls); case "$FW" in ''|*[!0-9]*) FW=0 ;; esac
    FW=$((FW + 1))
    state_set fastwalls "$FW"
    [ "$FW" = 1 ] && glog "wall ${AGE}s after a rotation — the identity is seconds old; waiting ${COOLDOWN_J}s"
    if [ "$FW" -ge 3 ]; then
      glog "three walls inside a minute of a fresh identity — account-side, parking rotations for 15 min"
      state_set last_hop "$((NOW + 900))"
      state_set fastwalls 0
      continue
    fi
  elif [ "$AGE" -ge 300 ]; then
    state_set fastwalls 0
  fi

  if [ "$AGE" -lt "$COOLDOWN_J" ]; then
    glog "wall seen but in cooldown (${AGE}s < ${COOLDOWN_J}s) — waiting"
    continue
  fi

  # warp must actually be usable, or a rotation would just wreck the network
  if ! wo status 2>/dev/null | head -1 | grep -q Connected; then
    glog "wall seen but warp is not connected — not rotating (no network surgery)"
    state_set last_hop "$NOW"
    continue
  fi

  OLD=$(cur_ip)
  OLD_SEEN4=$(seen4 2>/dev/null || true)
  # the quota key is the egress /64 the server sees, never the utun leg
  OLD_BLOCK=$(oui_bucket 2>/dev/null || true)
  [ -n "$OLD_BLOCK" ] || OLD_BLOCK=$(seen6_prefix 2>/dev/null || true)
  [ -n "$OLD_BLOCK" ] || OLD_BLOCK="$OLD"
  if ! rot_acquire; then
    glog "wall seen but another rotation has owned the tunnel for 5 minutes — not stacking a second one"
    continue
  fi
  glog "wall detected — rotating (was: ${OLD:-?} /64 ${OLD_BLOCK:-?})"
  # the /64 is the bucket, exactly like the linux build. fall back to the v4
  # address only when the tunnel has no v6 address at all.
  [ -n "$OLD_BLOCK" ] && oui_is_egress "$OLD_BLOCK" && blacklist_add "$OLD_BLOCK"
  oui_ledger "$OLD_BLOCK" wall 2>/dev/null || true

  NEW=""
  NEW_BUCKET=""
  TRY=0
  while [ "$TRY" -lt "$MAX_HOP_TRIES" ]; do
    TRY=$((TRY + 1))
    V=$(hop_with_timeout)
    NB=$(oui_bucket 2>/dev/null || true)
    if [ -z "$NB" ]; then
      NB=$(wait_bucket 12 2>/dev/null || true)
    fi
    if [ -z "$NB" ]; then
      glog "try $TRY: no cloudflare egress after rotation"
      continue
    fi
    # a fresh registration sitting on the old /64 is the old wall. this is
    # the check that used to be "device id changed" — and a new device id on
    # an unchanged block is not a new quota bucket, it is a no-op with a
    # green tick.
    if [ "$NB" = "$OLD_BLOCK" ]; then
      glog "try $TRY: same /64 ($NB) — bucket did not move"
      continue
    fi
    NEW="$V"
    NEW_BUCKET="$NB"
    break
  done

  # upstream parity: when every block is burnt, recycle the oldest — these
  # buckets reset around midnight anyway
  if [ -z "$NEW" ]; then
    glog "every block blacklisted — recycling oldest block"
    V=$(hop_with_timeout)
    NB=$(oui_bucket 2>/dev/null || true)
    if [ -n "$V" ] && [ -n "$NB" ]; then NEW="$V"; NEW_BUCKET="$NB"; fi
  fi
  if [ -z "$NEW" ]; then
    FAILS=$(( $(state_get fails 2>/dev/null || echo 0) + 1 ))
    case "$FAILS" in ''|*[!0-9]*) FAILS=1 ;; esac
    state_set fails "$FAILS"
    if [ "$FAILS" -ge 3 ]; then
      glog "three rotations failed in a row — cooling down for 10 minutes (account-side wall)"
      state_set last_hop "$((NOW + 600))"
      state_set fails 0
    else
      glog "rotation failed ($FAILS/3) — wall is likely account-side, not ip-side; keeping the tunnel"
    fi
  else
    state_set fails 0
  fi

  if [ -n "$NEW" ]; then
    state_set last_hop "$NOW"
    state_set current "$NEW"
    [ -n "$NEW_BUCKET" ] && state_set prefix "$NEW_BUCKET"
    NDEV=$(cur_device)
    [ -n "$NDEV" ] && state_set device "$NDEV"
    NS6=$(seen6 2>/dev/null || true)
    [ -n "$NS6" ] && state_set seen6 "$NS6"
    H=$(state_get hops); H=${H:-0}; H=$((H + 1))
    state_set hops "$H"
    oui_ledger "$NEW_BUCKET" hop 2>/dev/null || true
    glog "rotated #$H: ${OLD_BLOCK:-?} → $NEW_BUCKET ✓"
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
