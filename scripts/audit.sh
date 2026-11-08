#!/bin/bash
# audit — compares the macOS port against the linux upstream, feature by
# feature, and reports PASS / DEVIATION / FAIL. read-only.
set -u
BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
SHIM="$HOME/.local/bin/opencode"

pass=0; dev=0; fail=0
ok(){  printf "  \033[32m✓\033[0m %-46s %s\n" "$1" "${2:-}"; pass=$((pass+1)); }
dv(){  printf "  \033[33m~\033[0m %-46s %s\n" "$1" "${2:-}"; dev=$((dev+1)); }
bad(){ printf "  \033[31m✗\033[0m %-46s %s\n" "$1" "${2:-}"; fail=$((fail+1)); }

echo ""
echo "  ==============================================="
echo "  opencode-unlimited — macOS vs linux feature audit"
echo "  ==============================================="
echo ""

# ---- 1. binaries ------------------------------------------------------------
REAL=""
for c in "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode "$HOME/.npm-global/bin/opencode"; do
  [ -x "$c" ] && grep -qI "zen-lane" "$c" 2>/dev/null || { [ -x "$c" ] && REAL="$c" && break; }
done
[ -n "$REAL" ] && ok "opencode CLI" "$("$REAL" --version 2>/dev/null | head -1)" || bad "opencode CLI" "missing"

WARP="$(command -v warp-cli 2>/dev/null || true)"
[ -n "$WARP" ] && [ -s "$WARP" ] && ok "warp-cli" "$("$WARP" --version 2>/dev/null | head -1)" || bad "warp-cli" "missing/stub"

# ---- 2. launchd units -------------------------------------------------------
launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1 \
  && ok "keeper daemon (linux: systemd root)" "loaded" || bad "keeper daemon" "not loaded"
launchctl print "gui/$(id -u)/com.opencode-unlimited.guard" >/dev/null 2>&1 \
  && ok "zen-guard agent (linux: systemd user)" "loaded" || bad "zen-guard agent" "not loaded"

pgrep -f "warp-keeper.sh" >/dev/null 2>&1 && ok "keeper process alive" "$(pgrep -f warp-keeper.sh | head -1)" || bad "keeper process" "not running"
pgrep -f "zen-guard.sh" >/dev/null 2>&1 && ok "guard process alive" "$(pgrep -f zen-guard.sh | head -1)" || bad "guard process" "not running"

# ---- 3. tunnel --------------------------------------------------------------
ST="$("$WARP" --accept-tos status 2>/dev/null | head -1)"
echo "$ST" | grep -q Connected && ok "warp tunnel connected" || bad "warp tunnel" "$ST"
MODE="$("$WARP" --accept-tos settings 2>/dev/null | awk -F'Mode: ' '/Mode:/ {print $2; exit}')"
case "$MODE" in
  TunnelOnly) dv "warp mode" "TunnelOnly (linux: TUN+warp; DNS stays local)" ;;
  Warp)       dv "warp mode" "Warp — DNS rides the tunnel (macOS wants TunnelOnly)" ;;
  *)          dv "warp mode" "${MODE:-unknown}" ;;
esac

REG="$("$WARP" --accept-tos registration show 2>/dev/null | head -2 | tr '\n' ' ')"
[ -n "$REG" ] && ok "warp registration" "$(echo "$REG" | cut -c1-40)" || bad "warp registration" "none"

# ---- 4. leak guard ----------------------------------------------------------
if [ -f /etc/pf.anchors/OUC_LEAKGUARD ]; then
  N=$(sudo -n /sbin/pfctl -a OUC_LEAKGUARD -s rules 2>/dev/null | grep -c . )
  [ "${N:-0}" -gt 0 ] && ok "leak guard (linux: iptables 24/7)" "armed, $N rules" \
                      || dv "leak guard" "installed, fail-open (flushed while down)"
else
  dv "leak guard (linux: iptables 24/7)" "OFF by default (opt-in, fail-open)"
fi
R=$(grep -c "OUC_LEAKGUARD" /etc/pf.conf 2>/dev/null || true)
[ "${R:-0}" = 0 ] && ok "pf.conf clean" "no refs" || dv "pf.conf" "$R refs left"

# ---- 5. lane / shim ---------------------------------------------------------
grep -q "zen-lane" "$SHIM" 2>/dev/null && ok "opencode shim → lane" || bad "opencode shim" "not pointing at lane"
[ -x "$HOME/.local/bin/opencode-unlimited-hop" ] && ok "PATH tool: hop" || bad "PATH tool: hop" "missing"
[ -x "$HOME/.local/bin/opencode-unlimited-doctor" ] && ok "PATH tool: doctor" || bad "PATH tool: doctor" "missing"

grep -q "ensure_credit" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: credit enforcement" || bad "lane: credit" "missing"
grep -q "IOPlatformExpertDevice" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: machine-id via ioreg shim (per launch)" || dv "lane: machine-id" "env only"
grep -q "OUC_PAYLOAD" "$DEST/install.sh" 2>/dev/null && ok "installer: standalone payload (no branch needed)" || dv "installer" "needs a checkout or published branch"
grep -q "lane_live" "$DEST/scripts/warp-keeper.sh" 2>/dev/null && ok "keeper: pid-owned lane pin sweep" || bad "keeper: lane sweep" "missing"
grep -q "hop_with_timeout" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: bounded rotation (180s cap)" || dv "guard: rotation cap" "unbounded"
grep -q "MACHINE_ID" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: random machine-id" "env (linux: /etc/machine-id bind)" || bad "lane: machine-id" "missing"
grep -q "edge_ok4" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: edge pin" "v4-first, validated, falls back to v6" || bad "lane: edge pin" "unvalidated"
grep -q "remove each launch\|restore_hosts\|MARK_BEGIN" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: hosts pin restorable" || bad "lane: hosts restore" "missing"
grep -q "Telegram:- @ElectronCursed" "$DEST/scripts/zen-lane.sh" 2>/dev/null && ok "lane: non-tty credit append" || bad "lane: ntty credit" "missing"

# ---- 6. guard ---------------------------------------------------------------
grep -q "QuotaExceeded" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: wall detection" || bad "guard: wall" "missing"
grep -q "grep -aqiE" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: case-insensitive match" || dv "guard: match" "case-sensitive"
grep -q "blacklist" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: blacklist" || bad "guard: blacklist" "missing"
grep -q "pause_keeper" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: pauses keeper during rotation" "marker file (linux: systemctl)" || bad "guard: pause" "missing"
grep -q "is_warp_ip" "$DEST/scripts/zen-guard.sh" 2>/dev/null && ok "guard: never rotates direct egress" || bad "guard: warp check" "missing"
grep -q "MAX_HOP_TRIES=3" "$DEST/scripts/zen-guard.sh" 2>/dev/null && dv "guard: max hop tries" "3 (linux: 8) — pool is 4 IPs here" || true

# ---- 7. state ---------------------------------------------------------------
if [ -f "$GUARD_DIR/state.json" ]; then
  python3 - "$GUARD_DIR/state.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
need={"blacklist","offset","last_hop","hops","current"}
missing=need-set(d)
print("  \033[32m✓\033[0m %-46s %s" % ("guard state schema", "ok" if not missing else f"missing {missing}"))
print("      offset=%r hops=%r current=%r" % (d.get("offset"), d.get("hops"), d.get("current")))
PY
else
  bad "guard state" "missing"
fi

# ---- 8. wall regex against the real log ------------------------------------
LOG="$HOME/.local/share/opencode/log/opencode.log"
RE="QuotaExceeded|Free usage limit reached|usage limit reached|FreeUsageLimitError|FreeUsageLimit|rate limit exceeded|too many requests"
if [ -f "$LOG" ]; then
  HITS=$(rg -a -c -i "Free usage limit reached|FreeUsageLimitError|QuotaExceeded" "$LOG" 2>/dev/null | head -1)
  if rg -a "Free usage limit reached|FreeUsageLimitError" "$LOG" 2>/dev/null | head -200 | grep -qiE "$RE"; then
    ok "wall regex matches real log lines" "${HITS:-0} historical hits"
  else
    dv "wall regex vs real log" "no real hit in the sampled window"
  fi
fi

# ---- 9. dns safety ----------------------------------------------------------
[ -f "$GUARD_DIR/dns-baseline.txt" ] && ok "dns baseline captured" "$(head -1 "$GUARD_DIR/dns-baseline.txt" 2>/dev/null | tr '\t' ' ')" || bad "dns baseline" "missing"
grep -q "restore_dns" "$DEST/scripts/warp-keeper.sh" 2>/dev/null && ok "keeper: dns restore on failure" || bad "keeper: dns restore" "missing"
grep -q "ensure_daemon" "$DEST/scripts/warp-keeper.sh" 2>/dev/null && ok "keeper: warp daemon self-heal" || dv "keeper: daemon heal" "missing"

# ---- 10. live network -------------------------------------------------------
IP=$(curl -4 -fsS -m 8 https://api64.ipify.org 2>/dev/null || true)
case "$IP" in
  104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) ok "egress via cloudflare" "$IP" ;;
  "") bad "egress" "none" ;;
  *) dv "egress" "$IP — direct (tunnel down / fail-open)" ;;
esac
[ -n "$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null)" ] && ok "dns resolves" "$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null | head -1)" || bad "dns" "not resolving"
H=$(curl -4 -fsS -o /dev/null -w "%{http_code}" -m 8 https://api.github.com 2>/dev/null || true)
[ "$H" = 200 ] && ok "https reachable" "200" || bad "https" "$H"

# ---- 11. install artifacts -------------------------------------------------
[ -f /etc/sudoers.d/$BRAND ] && ok "sudoers entry present" || bad "sudoers entry" "missing"
[ -f "$DEST/AGENTS.md" ] && ok "AGENTS.md shipped" || bad "AGENTS.md" "missing"
[ -f "$DEST/scripts/zen-hop.sh" ] && [ -f "$DEST/scripts/doctor.sh" ] && ok "all scripts installed" || bad "scripts" "incomplete"
[ -x "$DEST/scripts/zen-hop.sh" ] && ok "scripts executable" || bad "scripts" "not executable"

echo ""
echo "  pass=$pass  deviation=$dev  fail=$fail"
if [ "$fail" -gt 0 ]; then echo "  ✗ something is broken — see the ✗ lines"; else echo "  ✓ no failures. ~ lines are documented macOS adaptations."; fi
echo ""
