#!/bin/bash
# warp keeper — keeps the cloudflare warp tunnel in TUN mode and the
# kill-switch firewall installed. runs as a root systemd service.
#
# every tick (45s):
#   - forces warp TUN mode
#   - reconnects if the tunnel died (fresh registration if the old one is toast)
#   - re-installs the OUC_LEAKGUARD iptables chain (survives manual flushes)
#
# the kill-switch: only loopback, LAN, cloudflare's control ranges, the warp
# interface and established connections may leave the host. everything else
# gets dropped. tunnel down? the chain is still there → traffic goes nowhere
# instead of leaking from your home IP. that's the whole point.
set -u

# warp binary: service env (installer sets it) → PATH → common fallbacks.
# we probe with --accept-tos and without: some boxes shim warp-cli with the
# flag already inside, and passing it twice kills the CLI with an arg error.
WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/bin/warp-cli ]; then WARP=/usr/bin/warp-cli
  elif [ -x "$HOME/.local/bin/warp-cli" ]; then WARP="$HOME/.local/bin/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }

w(){  "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; "$WARP" "$@" >/dev/null 2>&1; }
wo(){ "$WARP" --accept-tos "$@" 2>/dev/null && return 0; "$WARP" "$@" 2>/dev/null; }

IFACE=CloudflareWARP
TICK=45

ensure_connected(){
  wo status | head -1 | grep -q Connected && return 0
  w connect; sleep 4
  wo status | head -1 | grep -q Connected && return 0
  # old registration is probably dead — burn it and make a new one
  w disconnect
  w registration delete
  w registration new || return 1
  w mode warp
  w connect
  sleep 5
  wo status | head -1 | grep -q Connected
}

ensure_guard(){
  # ---- v4
  iptables  -N OUC_LEAKGUARD 2>/dev/null
  iptables  -F OUC_LEAKGUARD
  iptables  -A OUC_LEAKGUARD -o lo              -j ACCEPT
  iptables  -A OUC_LEAKGUARD -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables  -A OUC_LEAKGUARD -d 10.0.0.0/8      -j ACCEPT
  iptables  -A OUC_LEAKGUARD -d 172.16.0.0/12   -j ACCEPT
  iptables  -A OUC_LEAKGUARD -d 192.168.0.0/16  -j ACCEPT
  # cloudflare warp control/engage ranges (warp-cli needs these to talk home)
  iptables  -A OUC_LEAKGUARD -d 162.159.0.0/16  -j ACCEPT
  iptables  -A OUC_LEAKGUARD -d 188.114.0.0/16  -j ACCEPT
  iptables  -A OUC_LEAKGUARD -o $IFACE          -j ACCEPT
  iptables  -A OUC_LEAKGUARD -j DROP
  iptables  -C OUTPUT -j OUC_LEAKGUARD 2>/dev/null || iptables -I OUTPUT -j OUC_LEAKGUARD
  # ---- v6 (same idea)
  ip6tables -N OUC_LEAKGUARD 2>/dev/null
  ip6tables -F OUC_LEAKGUARD
  ip6tables -A OUC_LEAKGUARD -o lo   -j ACCEPT
  ip6tables -A OUC_LEAKGUARD -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUC_LEAKGUARD -d fe80::/10      -j ACCEPT
  ip6tables -A OUC_LEAKGUARD -d 2606:4700::/32 -j ACCEPT
  ip6tables -A OUC_LEAKGUARD -o $IFACE         -j ACCEPT
  ip6tables -A OUC_LEAKGUARD -j DROP
  ip6tables -C OUTPUT -j OUC_LEAKGUARD 2>/dev/null || ip6tables -I OUTPUT -j OUC_LEAKGUARD
}

# on very first boot the unit may start before network is up — be patient
for i in 1 2 3 4 5 6; do
  w status >/dev/null 2>&1 && break
  sleep 10
done

while true; do
  w mode warp
  ensure_connected || true
  ensure_guard
  sleep $TICK
done
