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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  # remember the model that just failed so the lever stops offering it, then
  # let the next pick land on one the console is actually serving.
  cur=$(python3 -c "import json,os
try: print((json.load(open(os.path.expanduser('$cfg'))).get('model') or '').split('/')[-1])
except Exception: print('')" 2>/dev/null)
  if [ -n "$cur" ] && [ -x "$SELF_DIR/model-levers.sh" ]; then
    bash "$SELF_DIR/model-levers.sh" dead "$cur" 400 >/dev/null 2>&1 \
      && glog "model $cur marked unavailable — the next pick skips it"
  fi
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
# every wall gets a record: which model, which provider, which key, which
# egress, and which proxy upstream carried it. without this, "which lever
# actually moves the wall" is an opinion; with it, it is a count.
# three landings in a row that take a wall inside ten minutes means the /64 is
# not the bucket any more. rotating then is a reconnect with a green tick, and
# this machine has paid for that lesson twice.
rotation_is_useless(){
  [ -s "$STATE_DIR/walls.jsonl" ] || return 1
  python3 - "$STATE_DIR/walls.jsonl" <<'PY' 2>/dev/null
import json,sys
try:
    ev=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception:
    raise SystemExit(1)
det=[e for e in ev if e.get("what")=="detected"]
land=[e for e in ev if e.get("what")=="landed"]
if len(land) < 3:
    raise SystemExit(1)
bad=0
for l in land:
    if any(0 <= d["ts"]-l["ts"] <= 600 for d in det):
        bad+=1
raise SystemExit(0 if bad*2 >= len(land) else 1)
PY
}

wall_event(){
  local what="$1" extra="${2:-}"
  python3 - "$STATE_DIR/walls.jsonl" "$what" "$extra" <<'PY' 2>/dev/null
import json,os,sys,subprocess,time
path,what,extra=sys.argv[1],sys.argv[2],sys.argv[3]
h=os.path.expanduser("~")
def jload(p, d=None):
    try: return json.load(open(p))
    except Exception: return d if d is not None else {}
conf=jload(os.path.join(h,".config/opencode/opencode.json"))
model=conf.get("model") or ""
prov=model.split("/")[0] if "/" in model else ""
mid=model.split("/")[-1] if "/" in model else model
st=jload(os.path.join(h,".local/share/opencode-unlimited/guard/state.json"))
px=jload(os.path.join(h,".local/share/opencode-unlimited/guard/proxy-state.json"))
rec={
 "ts":int(time.time()),
 "what":what,
 "extra":extra,
 "model":mid,
 "provider":prov,
 "bucket":st.get("current_block") or st.get("bucket") or "",
 "ip":st.get("current") or "",
 "proxy_up":bool(px.get("up")),
 "proxy_current":px.get("current") or "",
 "proxy_pool":px.get("pool") or 0,
 "rotations":st.get("hops") or 0,
}
try:
    with open(path,"a") as f: f.write(json.dumps(rec,separators=(",",":"))+"\n")
    if os.path.getsize(path) > 1000000:
        lines=open(path).readlines()[-2000:]
        open(path,"w").writelines(lines)
except Exception:
    pass
PY
}

model_provider(){
  python3 - <<'PY' 2>/dev/null
import json,os
try:
    d=json.load(open(os.path.expanduser("~/.config/opencode/opencode.json")))
    print((d.get("model") or "").split("/")[0])
except Exception:
    print("")
PY
}

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

# ---- the cheap identity: the console key ----------------------------------
# a wall can be keyed on the console account instead of the ip — but on this
# machine the ip is what has actually cleared walls, every time. so the key is
# a fallback used only when the /64 pool is out of fresh blocks: it costs
# nothing, it touches no tunnel. one wall after a swap is the verdict, and the
# verdict is remembered for the rest of the run.
KEYS_SCRIPT="$DEST/scripts/api-keys.sh"

keys_json(){ bash "$KEYS_SCRIPT" json 2>/dev/null || true; }
keys_live(){ keys_json | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(int(d.get("live") or 0))' 2>/dev/null || echo 0
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
# is the tunnel actually up, not just "we did not kill it".
tunnel_ensure(){
  local st i ip
  st=$(w status 2>/dev/null | tr -d '\r')
  case "$st" in
    *Connected*) ;;
    *)
      glog "tunnel is down after a hop — reconnecting before moving on"
      w connect >/dev/null 2>&1 || true
      ;;
  esac
  for i in $(seq 1 20); do
    ip=$(cur_ip)
    if [ -n "$ip" ]; then return 0; fi
    sleep 1
  done
  glog "tunnel did not come back within 20s — the keeper will keep trying (lanes stay fail-open)"
  return 1
}

hop_with_timeout(){
  local out p i
  out=$(mktemp /tmp/ouc-hop.XXXXXX 2>/dev/null) || { hop_once; return; }
  ( hop_once > "$out" 2>/dev/null ) &
  p=$!
  i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 90 ]; then
      # the old comment said "keeping the tunnel" while the child had already
      # disconnected it. reconnecting is the difference between a failed
      # rotation and a dead machine.
      glog "rotation exceeded 180s — killing it and restoring the tunnel"
      kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null
      tunnel_ensure || true
      break
    fi
    sleep 2
  done
  wait "$p" 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$out"
}

# the HUD's HOP and the guard's watcher can fire together. a second rotation
# while the first is mid-registration leaves the device unregistered, so take
# the lock or stand down. the lock is released by the wrapper below, not by a
# trap: macOS bash is 3.2 and has no RETURN trap, so a trap would leak the lock
# and freeze every future rotation.
hop_once(){
  if ! mkdir "$ROT_LOCK" 2>/dev/null; then
    echo ""
    return
  fi
  _hop_body
  local rc=$?
  rmdir "$ROT_LOCK" 2>/dev/null
  return $rc
}

_hop_body(){
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
  [ "$ok" = 1 ] || { tunnel_ensure || true; echo ""; return; }
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

# a lock left behind by a killed guard would freeze every future rotation.
if [ -d "$ROT_LOCK" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$ROT_LOCK" 2>/dev/null || echo 0) ))
  [ "$AGE" -gt 300 ] && rmdir "$ROT_LOCK" 2>/dev/null
fi

glog "zen-guard up (cooldown ${COOLDOWN}s, macOS, warp=$WARP)"
# a fresh run gets a fresh verdict on the key lever: the pool may have had a
# working key added since the last one gave up on it.
state_set key_fails 0
state_set key_pending 0
state_set last_key_hop 0

# one-time repair of a blacklist written before the identity rule existed.
# it holds the tunnel's inside leg and bare v4 duplicates on this box, and
# neither can ever match a bucket.
if [ -n "$(command -v oui_bl_migrate)" ]; then
  MIG=$(oui_bl_migrate 2>/dev/null || true)
  [ -n "$MIG" ] && glog "blacklist $MIG"
fi

# a one-shot way to prove the telemetry path without waiting for a wall.
# `zen-guard.sh wall-event detected manual` appends and exits.
if [ "${1:-}" = "wall-event" ]; then
  wall_event "${2:-detected}" "${3:-manual}"
  echo "appended to $STATE_DIR/walls.jsonl"
  exit 0
fi

while true; do
  rot_release
  trim_log "$GUARD_LOG"
  # safety net for the machine-wide switch: if the system proxy is pointed at
  # the mux and the mux is not running, every app on the box is talking to a
  # dead port. put the baseline back before anything else.
  if [ -f "$STATE_DIR/proxy-state.json" ]; then
    DEAD_SYS=$(python3 - "$STATE_DIR/proxy-state.json" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
print(1 if d.get("system") and not d.get("up") else 0)
PY
)
    if [ "${DEAD_SYS:-0}" = "1" ] && [ -x "$SELF_DIR/proxy-pool.sh" ]; then
      bash "$SELF_DIR/proxy-pool.sh" sys off >/dev/null 2>&1 \
        && glog "system proxy was pointed at a stopped mux — restored the baseline"
    fi
    # and the other half: the user turned the mux on, so it stays on. a crash,
    # a kill, a bad reboot of the listener is not a reason to silently go
    # direct — that is a quota leak with a green sheet.
    if [ -f "$STATE_DIR/proxy-want" ]; then
      MUX_LIVE=$(python3 - "$STATE_DIR/proxy-state.json" <<'PY' 2>/dev/null
import json,os,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
pid=int(d.get("pid") or 0)
alive=False
if pid:
    try:
        os.kill(pid, 0); alive=True
    except Exception:
        alive=False
print(1 if (d.get("up") and alive) else 0)
PY
)
      if [ "${MUX_LIVE:-1}" = "0" ] && [ -x "$SELF_DIR/proxy-pool.sh" ]; then
        bash "$SELF_DIR/proxy-pool.sh" on >/dev/null 2>&1 \
          && glog "proxy mux had stopped while it was wanted — restarted it"
      fi
    fi
  fi
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

  # ---- the key lever is a fallback, not the first move -------------------
  # ip rotation is the lever that has actually cleared walls on this machine,
  # so it stays the default. but if a swap of the console key did happen, the
  # next wall is the verdict: the key was not it. record that, park, and stop
  # spending the running CLI's credential on a hypothesis that already failed.
  if [ "$(state_get key_pending)" = "1" ]; then
    state_set key_pending 0
    state_set key_fails 2
    glog "the wall came back after the key swap — the key is not the lever; key rotation off for this run"
    glog "parking rotations 15 min (pool dry and the account is not it)"
    state_set last_hop "$(( $(date +%s) + 900 ))"
    continue
  fi

  # parked rotations put last_hop in the future, which makes AGE negative.
  # that is not "a wall zero seconds after a rotation" — read it as parked and
  # stay quiet, or every wall during a park refills the counter and re-parks.
  if [ "$AGE" -lt 0 ]; then
    glog "wall seen while rotations are parked ($(( -AGE / 60 ))m left) — waiting"
    continue
  fi

  # jitter the cooldown so repeated walls do not align to the same tick
  COOLDOWN_J=$(( COOLDOWN + (RANDOM % 10) ))
  # a wall that lands within three minutes of a rotation means the fresh
  # bucket did not help — it is the account or a cached session, not the ip.
  # burning another registration on a 30 s cadence just empties the pool of
  # fresh /64s for the moment you actually need one.
  if [ "$AGE" -lt 180 ]; then COOLDOWN_J=60; fi

  # count walls that arrive while the identity is still brand new. one is bad
  # luck, three in a row is the account — and no amount of /64s fixes that.
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt 60 ]; then
    FW=$(state_get fastwalls); case "$FW" in ''|*[!0-9]*) FW=0 ;; esac
    FW=$((FW + 1))
    state_set fastwalls "$FW"
    [ "$FW" = 1 ] && glog "wall ${AGE}s after a rotation — the identity is seconds old; waiting ${COOLDOWN_J}s"
    if [ "$FW" -ge 3 ]; then
      glog "three walls inside a minute of a fresh identity — account-side, parking rotations for 15 min"
      # no /64 fixes this, and the wall's own text names the cheaper lever:
      # "or switch models". say it once, in the log, and let olivia press it —
      # a stale session may not pick up a config change, so the guard never
      # switches models behind a running client.
      glog "the wall is not the ip right now — HUD → PROXY → MODELS, pick a free model"
    # a wall that survives a rotation is not about the ip. if the pinned model
    # is a free console model, try the pool once: pin the first model that
    # actually answers, and say so. provider models are never touched.
    if [ "$(model_provider)" = "opencode" ] && [ -x "$SELF_DIR/model-levers.sh" ]; then
      if nm=$(bash "$SELF_DIR/model-levers.sh" fallback 6 2>/dev/null); then
        [ -n "$nm" ] && glog "account-side wall — switched model to $nm"
      else
        glog "account-side wall and no free model answers — pin a provider model"
      fi
    fi
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
  wall_event "detected"
  # the /64 is the bucket, exactly like the linux build. fall back to the v4
  # address only when the tunnel has no v6 address at all.
  [ -n "$OLD_BLOCK" ] && oui_is_egress "$OLD_BLOCK" && blacklist_add "$OLD_BLOCK"
  oui_ledger "$OLD_BLOCK" wall 2>/dev/null || true

  if rotation_is_useless; then
    glog "the last rotations did not clear a wall — this is not the /64, going to the model lever first"
    if [ "$(model_provider)" = "opencode" ] && [ -x "$SELF_DIR/model-levers.sh" ]; then
      if nm=$(bash "$SELF_DIR/model-levers.sh" fallback 6 2>/dev/null); then
        [ -n "$nm" ] && glog "switched model to $nm instead of rotating"
        state_set last_hop "$((NOW + 600))"
        continue
      fi
    fi
    glog "no free model answers either — parking rotations 10 min instead of burning the tunnel"
    state_set last_hop "$((NOW + 600))"
    continue
  fi

  NEW=""
  NEW_BUCKET=""
  TRY=0
  COLLISIONS=0
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
      COLLISIONS=$((COLLISIONS + 1))
      continue
    fi
    # an already-burned block is not a fresh identity either, and this is the
    # check the loop was missing: it compared against the block we just left
    # and against nothing else, so it happily accepted a block burned hours
    # ago. b40:8 took a wall at 01:05 and took another one three minutes after
    # we landed back on it at 10:05 — nine hours apart, still burnt. a burnt
    # block is a guaranteed wall, not a gamble worth taking.
    if oui_bl_has "$NB"; then
      glog "try $TRY: /64 $NB is already burned — not a fresh identity"
      COLLISIONS=$((COLLISIONS + 1))
      continue
    fi
    NEW="$V"
    NEW_BUCKET="$NB"
    wall_event "landed" "$NB"
    break
  done

  # upstream recycles the oldest block here, on the theory that buckets reset
  # around midnight. this machine measured otherwise: b40:8 was walled at
  # 01:05 and walled again three minutes after we landed back on it at 10:05.
  # a burnt block stays burnt for the better part of a day, so "recycle the
  # oldest" is a guaranteed second wall wearing a rescue's clothes.
  #
  # when every try lands on a burned block, the pool is saturated right now.
  # that is a fact about cloudflare's allocation, not a bug in this loop, and
  # hammering the same eight blocks does not change it. keep the tunnel up so
  # dns stays alive, say so once, and let time hand out a different slice.
  if [ -z "$NEW" ] && [ "$COLLISIONS" -gt 0 ]; then
    state_set collisions "$COLLISIONS"
    # last resort, and only here: the /64 pool is out of fresh blocks, so the
    # one thing left worth trying is whether the wall is keyed on the console
    # account instead. it costs nothing and it does not touch the tunnel. if a
    # wall comes back afterwards, key_pending turns the lever off for good.
    KF=$(state_get key_fails); case "$KF" in ''|*[!0-9]*) KF=0 ;; esac
    if [ "$KF" -lt 2 ]; then
      KCOUNT=$(keys_json | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(int(d.get("count") or 0))' 2>/dev/null || echo 0)
      case "$KCOUNT" in ''|*[!0-9]*) KCOUNT=0 ;; esac
      if [ "$KCOUNT" -ge 2 ] && bash "$KEYS_SCRIPT" rotate next >/dev/null 2>&1; then
        state_set key_pending 1
        state_set last_key_hop "$NOW"
        glog "pool saturated ($COLLISIONS burned) — swapped the console key as the last lever (no tunnel surgery)"
        continue
      fi
    fi
    glog "every try landed on a burned /64 ($COLLISIONS wasted) — pool saturated, parking rotations 15 min"
    glog "the /64 pool is out of fresh blocks — switch to a free model in HUD → PROXY → MODELS"
    state_set last_hop "$((NOW + 900))"
    state_set pool_dry "$NOW"
    continue
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
    state_set collisions 0
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
