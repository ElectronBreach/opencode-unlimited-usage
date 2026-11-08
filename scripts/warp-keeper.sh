#!/bin/bash
# warp keeper — keeps the cloudflare warp tunnel up and the machine online.
# runs as a root LaunchDaemon on macOS.
#
# DESIGN RULE #1: this process may never leave the Mac without internet.
# The failure that broke this machine before was a pf lockout plus a dead
# WARP DNS resolver. Both are handled explicitly here:
#
#   * the pf leak guard is OPT-IN (OUC_LEAKGUARD=1) and OFF by default
#   * DNS is the primary health signal, checked every 5s
#   * if system DNS breaks while raw IP connectivity works, the keeper
#     restores the DNS baseline captured at install and flushes the guard
#   * if WARP is connected but DNS or egress stays broken for 15s, the
#     keeper disconnects WARP entirely and leaves direct egress in place
#   * if warp-cli is missing or dangling, the keeper cleans up any leftover
#     pf rules and exits clean (launchd does not restart it)
set -u

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ] || [ ! -s "$WARP" ] || ! "$WARP" --version >/dev/null 2>&1; then
  WARP=""
  for c in "$(command -v warp-cli 2>/dev/null)" /usr/local/bin/warp-cli /opt/homebrew/bin/warp-cli; do
    [ -n "$c" ] && [ -x "$c" ] && [ -s "$c" ] || continue
    "$c" --version >/dev/null 2>&1 || continue
    WARP="$c"; break
  done
fi

DEST="${OUC_HOME:-$HOME/.local/share/opencode-unlimited}"
GUARD_DIR="$DEST/guard"
ANCHOR_NAME="OUC_LEAKGUARD"
ANCHOR="/etc/pf.anchors/$ANCHOR_NAME"
PF_CONF="/etc/pf.conf"
PAUSE="$GUARD_DIR/keeper.pause"
LOG="$GUARD_DIR/keeper.log"
BASELINE="$GUARD_DIR/dns-baseline.txt"

TICK=45
FAST=5
LEAKGUARD="${OUC_LEAKGUARD:-0}"

mkdir -p "$GUARD_DIR"
klog(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---------------------------------------------------------------- cleanup ----
# Always leave the box in a state where internet works. Called on start and
# before any exit.
flatten(){
  pfctl -a "$ANCHOR_NAME" -F all >/dev/null 2>&1
  if grep -q "load anchor \"$ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null; then
    python3 - "$PF_CONF" "$ANCHOR_NAME" <<'PY' >/dev/null 2>&1
import sys
p, n = sys.argv[1:3]
lines = open(p).read().splitlines()
drop = {f'anchor "{n}"', f'load anchor "{n}" from "/etc/pf.anchors/{n}"'}
open(p, "w").write("\n".join(l for l in lines if l.strip() not in drop) + "\n")
PY
    pfctl -f "$PF_CONF" >/dev/null 2>&1
  fi
  rm -f "$ANCHOR"
}

# ---------------------------------------------------------------- dns --------
active_service(){
  local dev svc
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$dev" ] || return 1
  svc=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v d="Device: $dev" '
    /^\(\*?[0-9]+\)/ {name=$0; sub(/^\(\*?[0-9]+\) /,"",name)}
    index($0,d) {print name; exit}')
  [ -n "$svc" ] && printf '%s' "$svc"
}

restore_dns(){
  local restored=0 svc servers
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
    svc=$(active_service)
    [ -n "$svc" ] && networksetup -setdnsservers "$svc" 1.1.1.1 8.8.8.8 >/dev/null 2>&1
  fi
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
  klog "dns: baseline restored + cache flushed"
}

dns_ok(){ [ -n "$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null)" ]; }
raw_ok(){ curl -k -fsS -o /dev/null --connect-timeout 3 --max-time 5 https://1.1.1.1 2>/dev/null; }
egress_ok(){ [ -n "$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://api64.ipify.org 2>/dev/null)" ]; }

# ---------------------------------------------------------------- warp -------
w(){  "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; "$WARP" "$@" >/dev/null 2>&1; }
wo(){ "$WARP" --accept-tos "$@" 2>/dev/null && return 0; "$WARP" "$@" 2>/dev/null; }
connected(){ wo status 2>/dev/null | head -1 | grep -q Connected; }

WANT_MODE="${OUC_WARP_MODE:-tunnel_only}"

cur_mode(){
  wo settings 2>/dev/null | awk -F'Mode: ' '/Mode:/ {print $2; exit}' \
    | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | tr -d '_-'
}

ensure_mode(){
  local m want
  m=$(cur_mode)
  [ -n "$m" ] || return 0
  want=$(printf '%s' "$WANT_MODE" | tr '[:upper:]' '[:lower:]' | tr -d '_-')
  [ "$m" = "$want" ] && return 0
  w mode "$WANT_MODE" >/dev/null 2>&1 || true
}

ensure_connected(){
  connected && return 0
  w connect; sleep 4
  connected && return 0
  w disconnect
  w registration delete
  w registration new || return 1
  w connect
  sleep 5
  connected
}

# ---------------------------------------------------------------- guard ------
utuns(){
  local out="" i
  for i in $(seq 0 15); do
    ifconfig "utun$i" >/dev/null 2>&1 && out="$out utun$i"
  done
  printf '%s' "${out# }"
}

write_anchor(){
  local list ifb=""
  list=$(utuns)
  [ -z "$list" ] && return 1
  for i in $list; do ifb="$ifb pass out quick on $i all"$'\n'; done
  cat > "$ANCHOR" <<EOF
# OUC_LEAKGUARD — generated $(date '+%F %T'), OPT-IN
pass out quick on lo0 all
pass out quick inet proto udp from any port 68 to any port 67
pass out quick inet from any to 10.0.0.0/8
pass out quick inet from any to 172.16.0.0/12
pass out quick inet from any to 192.168.0.0/16
pass out quick inet from any to 169.254.0.0/16
pass out quick inet from any to 224.0.0.0/4
pass out quick inet6 from any to fe80::/10
pass out quick inet6 from any to fc00::/7
pass out quick inet proto udp to any port 2408
pass out quick inet proto udp to any port 500
pass out quick inet proto udp to any port 4500
pass out quick inet to 162.159.0.0/16
pass out quick inet to 188.114.0.0/16
pass out quick inet to 172.64.0.0/13
pass out quick inet6 to 2606:4700::/32
${ifb}block drop out quick all
EOF
  chmod 644 "$ANCHOR"
}

pfconf_add(){
  grep -q "load anchor \"$ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null && return 0
  [ -f "$PF_CONF.ouc.bak" ] || cp "$PF_CONF" "$PF_CONF.ouc.bak"
  python3 - "$PF_CONF" "$ANCHOR_NAME" "$ANCHOR" <<'PY'
import sys
path, name, anchor = sys.argv[1:4]
lines = open(path).read().splitlines()
block = [f'anchor "{name}"', f'load anchor "{name}" from "{anchor}"']
out, placed = [], False
for line in lines:
    s = line.strip()
    if not placed and (s.startswith('anchor "com.apple/*"') or s.startswith('load anchor "com.apple"')):
        out.extend(block); placed = True
    out.append(line)
if not placed: out.extend(block)
open(path, "w").write("\n".join(out) + "\n")
PY
}

arm_guard(){
  write_anchor || return 1
  pfconf_add
  pfctl -n -f "$PF_CONF" >/dev/null 2>&1 || return 1
  pfctl -f "$PF_CONF" >/dev/null 2>&1
  pfctl -a "$ANCHOR_NAME" -f "$ANCHOR" >/dev/null 2>&1
  pfctl -E >/dev/null 2>&1
}

disarm_guard(){ pfctl -a "$ANCHOR_NAME" -F all >/dev/null 2>&1; }

paused(){
  [ -f "$PAUSE" ] || return 1
  local age
  age=$(( $(date +%s) - $(stat -f %m "$PAUSE" 2>/dev/null || echo 0) ))
  [ "$age" -lt 180 ]
}

# ---------------------------------------------------------------- boot -------
flatten

if [ -z "$WARP" ]; then
  klog "warp-cli missing or broken — pf leftovers cleared, keeper exiting (direct egress)"
  exit 0
fi

for i in 1 2 3 4 5 6; do
  wo status >/dev/null 2>&1 && break
  sleep 10
done

klog "keeper up (macOS / launchd, tick ${TICK}s, leakguard=${LEAKGUARD}, warp=$WARP)"
bad_ticks=0
dns_fixes=0
last_dns_fix=0
loops=0

while true; do
  if paused; then sleep "$FAST"; continue; fi

  # ---- health: DNS first, then egress -------------------------------------
  if raw_ok; then
    if ! dns_ok; then
      now=$(date +%s)
      if [ $((now - last_dns_fix)) -ge 30 ]; then
        klog "system dns broken while network is up — restoring baseline"
        restore_dns
        last_dns_fix=$now
        dns_fixes=$((dns_fixes + 1))
      fi
    fi
  fi

  if connected && ! egress_ok; then
    bad_ticks=$((bad_ticks + 1))
  elif connected && ! dns_ok; then
    bad_ticks=$((bad_ticks + 1))
  else
    bad_ticks=0
  fi

  # 3 consecutive bad checks (~15s) while "connected" = the tunnel is lying
  if [ "$bad_ticks" -ge 3 ]; then
    klog "tunnel reports connected but dns/egress dead — disconnecting warp (fail-open)"
    disarm_guard
    w disconnect >/dev/null 2>&1 || true
    restore_dns
    bad_ticks=0
  fi

  sleep "$FAST"

  # ---- slow path: connection + optional guard (every ~45s) ----------------
  loops=$((loops + 1))
  [ "$loops" -ge 9 ] || continue
  loops=0

  if ensure_connected; then
    if [ "$LEAKGUARD" = "1" ] && dns_ok && egress_ok; then
      if ! grep -q "load anchor \"$ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null; then
        arm_guard && klog "leak guard armed (opt-in, tunnel healthy)"
      fi
    elif [ "$LEAKGUARD" != "1" ]; then
      # opt-in is off — make sure nothing is left armed from a past run
      if grep -q "load anchor \"$ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null; then
        klog "leak guard is OFF by config — removing leftover rules"
        flatten
      fi
    fi
  else
    if grep -q "load anchor \"$ANCHOR_NAME\"" "$PF_CONF" 2>/dev/null; then
      klog "tunnel down — flushing leak guard (fail-open)"
      flatten
    fi
    dns_ok || restore_dns
  fi
done
