#!/bin/bash
# parity — runs upstream's features as behaviour, not as grep. every check does
# the thing the linux build does and reports PASS / ADAPT / FAIL.
set -u
B=opencode-unlimited
DEST="$HOME/.local/share/$B"
G="$DEST/guard"
S="$DEST/scripts"
LOG="$HOME/.local/share/opencode/log/opencode.log"
PASS=0; ADAPT=0; FAIL=0
p(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %-40s %s\n' "$1" "${2:-}"; }
a(){ ADAPT=$((ADAPT+1)); printf '  \033[33m~\033[0m %-40s %s\n' "$1" "${2:-}"; }
f(){ FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %-40s %s\n' "$1" "${2:-}"; }
have(){ [ -x "$1" ] || command -v "$1" >/dev/null 2>&1; }

echo ""; echo "  opencode-unlimited — behavioural parity (macOS vs linux upstream)"; echo ""

# 1 installer
grep -q "OUC_PAYLOAD" "$DEST/scripts/../install.sh" 2>/dev/null && p "install: standalone one-file" || a "install: standalone payload" "not in DEST (repo only)"

# 2 lane binary resolution
grep -q "zen-lane" "$HOME/.local/bin/opencode" 2>/dev/null && p "lane: shim owns PATH" || f "lane: shim" "not pointing at lane"

# 3 edge pin per launch (v6 preferred)
# a pin held by a LIVE lane (an open opencode session) is legitimate: the lane
# refuses to steal it, and the pin goes away when that session exits.
lane_owner_live(){
  local pid; pid=$(cat "$G/lane.pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" 2>/dev/null | grep -q zen-lane.sh
}
PINS=""
for i in 1 2 3; do
  OUC_REAL_BIN=/bin/sleep bash "$S/zen-lane.sh" 2 >/dev/null 2>&1 &
  sleep 1.5
  PINS="$PINS $(awk '/lane >>>/{getline; print $1}' /etc/hosts)"
  wait
done
UNIQ=$(printf '%s\n' $PINS | sort -u | grep -c .)
V6=$(printf '%s\n' $PINS | grep -c ":" || true)
if lane_owner_live; then
  a "lane: pin held by a live session" "$(awk '/lane >>>/{getline; print $1}' /etc/hosts)"
elif [ "$UNIQ" -ge 1 ] && [ "$V6" -ge 1 ]; then
  p "lane: pin applies (v6 edge)" "$UNIQ distinct / $V6 v6"
else
  a "lane: pin" "v4 fallback in use"
fi
if grep -q "opencode-unlimited" /etc/hosts; then
  if lane_owner_live; then a "lane: hosts pin owned by live session"; else f "lane: hosts restored" "pin survived exit"; fi
else
  p "lane: hosts restored" "0 markers"
fi

# 4 credit enforcement
printf 'tampered\n' > "$HOME/.opencode/AGENTS.md"
OUC_REAL_BIN=/bin/sleep bash "$S/zen-lane.sh" 1 >/dev/null 2>&1 || true
if grep -q "Telegram:- @ElectronCursed" "$HOME/.opencode/AGENTS.md"; then p "lane: credit byte-exact"; else f "lane: credit" "not restored"; fi

# 5 non-tty credit append
OUT=$(OUC_REAL_BIN=/bin/echo bash "$S/zen-lane.sh" run hi 2>/dev/null)
case "$OUT" in *"Telegram:- @ElectronCursed"*) p "lane: non-tty append" ;; *) f "lane: non-tty append" "missing" ;; esac

# 6 wall detection + rotation + /64 blacklist
OFF=$(python3 -c "import json;print(int(json.load(open('$G/state.json'))['offset']))" 2>/dev/null || echo 0)
H0=$(python3 -c "import json;print(json.load(open('$G/state.json')).get('hops',0))" 2>/dev/null || echo 0)
printf '\n{"error":{"code":429,"message":"Free usage limit reached"}}\n' >> "$LOG"
sleep 30
H1=$(python3 -c "import json;print(json.load(open('$G/state.json')).get('hops',0))" 2>/dev/null || echo 0)
BL=$(python3 -c "import json;d=json.load(open('$G/state.json'));print(sum(1 for x in d.get('blacklist',[]) if ':' in x))" 2>/dev/null || echo 0)
[ "$H1" -gt "$H0" ] && p "guard: wall → rotation" "hops $H0 → $H1" || f "guard: wall rotation" "no hop"
[ "${BL:-0}" -gt 0 ] && p "guard: blacklists the /64" "$BL v6 blocks" || a "guard: blacklist" "v4 only"

# 7 cooldown
grep -q "in cooldown" "$G/guard.log" 2>/dev/null && p "guard: cooldown honoured" || a "guard: cooldown" "not observed this run"

# 8 keeper alive + tunnel
pgrep -f warp-keeper.sh >/dev/null && p "keeper: daemon alive" "$(pgrep -f warp-keeper.sh | head -1)" || f "keeper" "not running"
pgrep -f zen-guard.sh  >/dev/null && p "guard: agent alive"  "$(pgrep -f zen-guard.sh | head -1)" || f "guard" "not running"
ST=$(/usr/local/bin/warp-cli --accept-tos status 2>/dev/null | head -1)
case "$ST" in *Connected*) p "warp: tunnel up" ;; *) f "warp" "$ST" ;; esac
MODE=$(/usr/local/bin/warp-cli --accept-tos settings 2>/dev/null | awk -F'Mode: ' '/\(user set\)/{print $2; exit}')
[ "$MODE" = "TunnelOnly" ] && a "warp: TunnelOnly (linux uses TUN+warp)" || a "warp: $MODE" "mode differs"

# 9 hop
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
I0=$(curl -4 -s -m 6 https://api64.ipify.org)
D0=$(/usr/local/bin/warp-cli --accept-tos registration show 2>/dev/null | awk '/^ID:/{print $2}')
opencode-unlimited-hop >/dev/null 2>&1
D1=$(/usr/local/bin/warp-cli --accept-tos registration show 2>/dev/null | awk '/^ID:/{print $2}')
[ -n "$D1" ] && [ "$D0" != "$D1" ] && p "hop: new device identity" "${D0:0:8}… → ${D1:0:8}…" || f "hop" "device unchanged"

# 10 dns safety
dig +short +time=1 +tries=1 opencode.ai 2>/dev/null | grep -q . && p "dns: resolves" || f "dns" "dead"
[ "$(curl -4 -s -o /dev/null -w '%{http_code}' -m 6 https://opencode.ai)" = "200" ] && p "https: 200" || f "https" "not 200"

# 11 state schema
python3 - "$G/state.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
need={"blacklist","offset","last_hop","hops","current"}
print("  \033[32m✓\033[0m %-40s %s" % ("state: schema", "ok" if not need-set(d) else f"missing {need-set(d)}"))
PY

echo ""
echo "  pass=$PASS  adapt=$ADAPT  fail=$FAIL"
echo ""
