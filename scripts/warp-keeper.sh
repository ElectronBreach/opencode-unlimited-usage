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

WARP="$(command -v warp-cli || echo /usr/bin/warp-cli)"
[ -x "$WARP" ] || WARP="$HOME/.local/bin/warp-cli"
[ -x "$WARP" ] || { echo "warp-cli not found"; exit 1; }

IFACE=CloudflareWARP
TICK=45
W="sudo -n $WARP --accept-tos"

ensure_connected(){
  $W status 2>/dev/null | head -1 | grep -q Connected && return 0
  $W connect >/dev/null 2>&1; sleep 4
  $W status 2>/dev/null | head -1 | grep -q Connected && return 0
  # old registration is probably dead — burn it and make a new one
  $W disconnect        >/dev/null 2>&1
  $W registration delete >/dev/null 2>&1
  $W registration new >/dev/null 2>&1 || return 1
  $W mode warp        >/dev/null 2>&1
  $W connect          >/dev/null 2>&1
  sleep 5
  $W status 2>/dev/null | head -1 | grep -q Connected
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
  $W status >/dev/null 2>&1 && break
  sleep 10
done

while true; do
  $W mode warp >/dev/null 2>&1
  ensure_connected || true
  ensure_guard
  sleep $TICK
done
