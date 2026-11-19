#!/bin/bash
# doctor — tells you what's alive and what needs attention. no fixes, just
# the truth (macOS port). run it whenever something feels off.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
ANCHOR_NAME="OUC_LEAKGUARD"
OUC_APP="$HOME/Library/Application Support/opencode-unlimited"
OUC_STATE="$OUC_APP/state.json"
OUC_BLACKLIST="$OUC_APP/blacklist.json"
OUC_HISTORY="$OUC_APP/history.jsonl"

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/local/bin/warp-cli ]; then WARP=/usr/local/bin/warp-cli
  elif [ -x /opt/homebrew/bin/warp-cli ]; then WARP=/opt/homebrew/bin/warp-cli
  elif [ -x "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" ]; then WARP="/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found — install it first"; exit 1; }

wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo ""
echo "  ============================="
echo "  Opencode Unlimited — doctor (macOS)"
echo "  ============================="
echo ""

# ---- keeper (macOS port runs it as a user agent; fall back to the old daemon)
# canonical stack keeps the tunnel with the root keeper daemon; the ouc user
# agent is only a fallback. either one being up means the keeper is healthy.
if launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1; then
  ok "warp keeper (root daemon, com.opencode-unlimited.keeper)"
elif launchctl print "gui/$(id -u)/com.ouc.keeper" >/dev/null 2>&1; then
  ok "warp keeper (user agent, com.ouc.keeper)"
else
  bad "keeper down — sudo launchctl bootstrap system /Library/LaunchDaemons/com.opencode-unlimited.keeper.plist"
fi

# ---- cloudflare daemon (its own launchd job)
if launchctl print system/com.cloudflare.1dot1dot1dot1.macos.warp.daemon >/dev/null 2>&1; then
  ok "cloudflare warp daemon"
else
  bad "cloudflare daemon down — keeper re-bootstraps it within ~45s"
fi

# ---- warp tunnel
ST=$(wo status | head -1)
echo "$ST" | grep -q Connected \
  && ok "warp tunnel: connected" \
  || bad "warp not connected — keeper repairs within ~45s (or restart it)"

MODE=$(wo settings 2>/dev/null | awk -F'Mode: ' '/Mode:/ {print $2; exit}')
case "$MODE" in
  TunnelOnly) ok "warp mode: TunnelOnly (dns stays local)" ;;
  Warp)       warn "warp mode: Warp (dns rides the tunnel — keeper will switch it)" ;;
  "")         warn "warp mode: unreadable" ;;
  *)          warn "warp mode: $MODE" ;;
esac

PFX=$(ifconfig 2>/dev/null | awk '/^utun/{i=$1} /inet6 26[0-9a-f]*:/{print $2}' | head -1 | cut -d/ -f1 | awk -F: '{print $1":"$2":"$3":"$4}')
# the quota key is what the server sees. on a network with IPv6 that is the
# egress /64; on a v4-only network there is no server-seen v6 at all and the
# tunnel leg is the only /64 that moves.
PFX_INFO=$(python3 - "$OUC_STATE" "$GUARD_DIR/state.json" <<'PY' 2>/dev/null
import json, sys
def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}
new = load(sys.argv[1])
leg = load(sys.argv[2])
if new:
    rot = new.get("last_rotation") if isinstance(new.get("last_rotation"), dict) else {}
    p = new.get("current_64") or ""
    kind = rot.get("kind") or ""
    if p and kind == "v6":
        print("seen|%s" % p)
    elif p:
        print("tunnel|%s" % p)
    else:
        print("none|")
elif leg.get("prefix"):
    print("seen|%s" % leg["prefix"])
else:
    print("none|")
PY
)
PFX_KIND=${PFX_INFO%%|*}
SEENPFX=${PFX_INFO#*|}
if [ "$PFX_KIND" = "seen" ] && [ -n "$SEENPFX" ]; then
  ok "server-seen /64: $SEENPFX (quota key)"
elif [ "$PFX_KIND" = "tunnel" ] && [ -n "$SEENPFX" ]; then
  ok "tunnel /64: $SEENPFX (rotates; this network has no v6 egress)"
elif [ -n "$PFX" ]; then
  warn "no /64 recorded — tunnel leg is $PFX (run: ouc hop --where)"
else
  warn "warp ipv6 /64: none — falling back to the 4 v4 addresses"
fi

# ---- api-key pool. the pool size is not capacity: a revoked key answers 401
# and keeps its row forever, so nine keys can mean nine dead ones.
# ocul does not put keys on the path at all — it rotates the warp egress — so an
# unverified pool is not a fault there, it is a drawer nobody opens.
OCUL_OWNS=$(python3 -c "import json;print((json.load(open('$GUARD_DIR/proxy-state.json')).get('by') or ''))" 2>/dev/null)
if [ "$OCUL_OWNS" = "ocul" ] && [ -x "$DEST/scripts/api-keys.sh" ]; then
  KN_OCUL=$(bash "$DEST/scripts/api-keys.sh" json 2>/dev/null | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("count") or 0))
except Exception: print(0)' 2>/dev/null)
  ok "api key pool idle ($KN_OCUL keys) — ocul rotates the warp egress, keys are not on the path"
elif [ -x "$DEST/scripts/api-keys.sh" ]; then
  KJ=$(bash "$DEST/scripts/api-keys.sh" json 2>/dev/null)
  read -r KN KLIVE KDEAD KACT KACTLIVE <<EOF
$(printf '%s' "$KJ" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("0 0 0 - None"); raise SystemExit
print(d.get("count",0), d.get("live",0), d.get("dead",0),
      (d.get("active") or "-").replace(" ","_"), d.get("activeLive"))
' 2>/dev/null)
EOF
  KN=${KN:-0}; KLIVE=${KLIVE:-0}; KDEAD=${KDEAD:-0}
  KUNK=$(printf '%s' "$KJ" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("unknown") or 0))
except Exception: print(0)' 2>/dev/null)
  KUNK=${KUNK:-0}
  if [ "$KN" -gt 0 ] && [ "$KLIVE" -eq 0 ] && [ "$KDEAD" -gt 0 ]; then
    warn "api keys: $KN in the pool, $KLIVE live — the console rejects every one (a working key is the only fix)"
  elif [ "$KN" -gt 0 ] && [ "$KLIVE" -eq 0 ]; then
    warn "api keys: $KN in the pool, none verified yet — bash $DEST/scripts/api-keys.sh health"
  elif [ "$KDEAD" -gt 0 ]; then
    ok "api keys: $KLIVE live of $KN ($KDEAD rejected — clean them from the KEYS tab)"
  else
    ok "api keys: $KLIVE live of $KN"
  fi
fi

# ---- leak guard (opt-in)
if [ -f /etc/pf.anchors/OUC_LEAKGUARD ]; then
  RULES=$(sudo -n /sbin/pfctl -a OUC_LEAKGUARD -s rules 2>/dev/null | grep -c . )
  if [ "${RULES:-0}" -gt 0 ]; then
    ok "leak guard armed ($RULES rules, drops non-tunnel egress)"
  else
    warn "leak guard installed but empty (fail-open while the tunnel is down)"
  fi
else
  ok "leak guard off (opt-in default, zero pf risk)"
fi

# ---- egress
# probe a literal IP first. resolving first is how a DNS hiccup gets misread
# as "no internet", which is the wrong diagnosis and the wrong advice.
TRACE=$(curl -4 -s -m 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
IP=$(printf '%s\n' "$TRACE" | awk -F= '/^ip=/{print $2; exit}')
[ -n "$IP" ] || IP=$(curl -4 -s -m 8 https://api64.ipify.org 2>/dev/null | tr -d '\n')
case "$IP" in *[!0-9a-f:.]*) IP="" ;; esac

if [ -n "$IP" ]; then
  case "$IP" in
    104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) ok "egress is cloudflare (warp): $IP" ;;
    *) warn "egress is NOT warp ($IP) — tunnel down or fail-open engaged" ;;
  esac
else
  # distinguish "no packets" from "name lookup is wedged". the browser cares
  # about the second one, and it is repaired differently.
  if curl -4 -s -o /dev/null -m 4 https://1.1.1.1 2>/dev/null; then
    bad "egress answers on a literal IP but not by name — run: sudo killall -HUP mDNSResponder"
  else
    bad "no egress at all — check Wi-Fi first, then the keeper"
  fi
fi

# ---- DNS (the thing that bit this machine last time)
A=$(dig +short +time=2 +tries=1 opencode.ai 2>/dev/null | head -1)
G=$(host -W 2 github.com 2>/dev/null | awk '/has address/{print $4; exit}')
if [ -n "$A" ]; then
  ok "dns: opencode.ai resolves ($A)$([ -n "$G" ] && echo " · github $G")"
else
  bad "dns: opencode.ai does not resolve — keeper restores the baseline automatically, or: sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
fi
# getaddrinfo is the path every app (and curl) actually uses — dig answering is
# not proof that a browser can resolve. check the real resolver too.
if python3 -c "import socket,sys; socket.setdefaulttimeout(4); socket.getaddrinfo('github.com',443,socket.AF_INET)" >/dev/null 2>&1; then
  ok "dns: system resolver healthy (getaddrinfo)" "github.com via getaddrinfo"
else
  bad "dns: system resolver wedged (dig ok, getaddrinfo fails) — sudo killall -HUP mDNSResponder"
fi

# ---- warp ui (the window, not the tunnel)
WGUI=$(pgrep -f "Cloudflare WARP.app/Contents/MacOS/Cloudflare WARP$" 2>/dev/null | head -1)
if [ -n "${WGUI:-}" ]; then
  ok "cloudflare warp UI running" "pid $WGUI"
else
  warn "cloudflare warp UI not running" "tunnel is unaffected — click the WARP chip in the HUD, or the menu bar item"
fi

# ---- guard (macOS port agent first, legacy agent second)
# the ocul guard is the canonical rotator on this Mac.
if launchctl print "gui/$(id -u)/ai.ocul.guard" >/dev/null 2>&1; then
  ok "guard agent (user, ai.ocul.guard)"
elif launchctl print "gui/$(id -u)/com.ouc.guard" >/dev/null 2>&1; then
  ok "guard agent (user, com.ouc.guard)"
elif launchctl print "gui/$(id -u)/com.opencode-unlimited.guard" >/dev/null 2>&1; then
  warn "legacy zen-guard agent — see: ouc doctor"
else
  bad "guard down — launchctl kickstart -k gui/$(id -u)/ai.ocul.guard"
fi

# ---- engine state (ouc state first, legacy guard json second)
STATE_SRC="$OUC_STATE"
[ -f "$STATE_SRC" ] || STATE_SRC="$GUARD_DIR/state.json"
if [ -f "$STATE_SRC" ]; then
  python3 - "$STATE_SRC" "$GUARD_DIR/identities.json" "$OUC_BLACKLIST" "$OUC_HISTORY" <<'PY'
import json, os, sys

src, ledger, blfile, hist = sys.argv[1:5]
cache = os.path.expanduser("~/.local/share/opencode-unlimited/guard/status-cache.json")

def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

d = load(src, {})
d = d if isinstance(d, dict) else {}
blocks = [b for b in (load(blfile, {}).get('blocks') or []) if b]
legacy = [x for x in (d.get('blacklist') or []) if x]
known = blocks or legacy
bucket = d.get('current_64') or d.get('prefix') or '?'
burnt = bucket in known
engine = 'ouc' if (d.get('current_64') or d.get('current_v4')) else 'legacy'
rot = d.get('last_rotation') if isinstance(d.get('last_rotation'), dict) else {}
led = {}
try:
    led = (load(ledger, {}).get('buckets') or {}).get(bucket, {})
except Exception:
    led = {}
total = 0
try:
    with open(hist) as f:
        for line in f:
            if '"ok": true' in line:
                total += 1
except Exception:
    total = 0
if not total:
    total = int(d.get('hops') or 0)
device = (rot.get('new_device') or d.get('device') or load(cache, {}).get('device') or '?')
print(f"    engine: {engine} · rotations so far: {total} · blacklisted buckets: {len(known)}")
print(f"    identity: {bucket} · device {str(device)[:8]}…")
exit4 = d.get('current_v4') or ''
if exit4:
    print(f"    ipv4 exit: {exit4}" + ("" if rot.get('v4_changed') else " (shared colo)"))
if d.get('fail_streak'):
    print(f"    backoff: streak {d.get('fail_streak')} · last error: {d.get('last_error') or '?'}")
print(f"    bucket state: {'BURNT' if burnt else 'fresh'} · walls {led.get('walls', 0)} · hops {led.get('hops', 0)}")
PY
fi

# ---- TUI shim
if [ -f "$HOME/.local/bin/opencode" ] && grep -q "zen-lane" "$HOME/.local/bin/opencode" 2>/dev/null; then
  ok "opencode entry → lane"
else
  warn "opencode entry doesn't point at the lane — reinstall or check ~/.local/bin/opencode"
fi

# ---- overlay HUD (hop + doctor + live token ledger, one window)
APP="$HOME/Library/Application Support/opencode-unlimited/OpencodeOverlay.app"
if [ -x "$APP/Contents/MacOS/opencode-unlimited-overlay" ]; then
  hud_up(){ pgrep -f "OpencodeOverlay.app/Contents/MacOS/opencode-unlimited-overlay" >/dev/null 2>&1; }
  if [ -n "${OUC_OVERLAY_PID:-}" ] && kill -0 "$OUC_OVERLAY_PID" 2>/dev/null; then
    # running from inside the HUD: it is up by definition
    ok "overlay HUD running (pid $OUC_OVERLAY_PID — this console)"
  elif hud_up; then
    ok "overlay HUD running (pid $(pgrep -f "OpencodeOverlay.app/Contents/MacOS/opencode-unlimited-overlay" | head -1))"
  else
    # the HUD is meant to be always up. if it is not, start it here rather than
    # reporting a warning the user has to go and fix by hand.
    open -g "$APP" >/dev/null 2>&1
    for _ in $(seq 1 10); do sleep 1; hud_up && break; done
    if hud_up; then
      ok "overlay HUD was down — restarted it now"
    else
      warn "overlay HUD will not start — bash $DEST/scripts/overlay/build.sh"
    fi
  fi
else
  warn "overlay HUD not built — bash $DEST/scripts/overlay/build.sh"
fi

# ---- proxy layer — ocul owns the lane when it publishes proxy-state.json
python3 - "$GUARD_DIR/proxy-state.json" "$DEST/proxies.txt" "$GUARD_DIR/state.json" <<'PY'
import json,os,subprocess,sys
state_p,pool_p,ident_p=sys.argv[1:4]
st={}
try: st=json.load(open(state_p))
except Exception: st={}
ident={}
try: ident=json.load(open(ident_p))
except Exception: pass
pool=0
try:
    for line in open(pool_p):
        line=line.strip()
        if line and not line.startswith("#"): pool+=1
except Exception: pass
up=bool(st.get("up"))
pid=st.get("pid") or 0
alive=False
if up and pid:
    try:
        os.kill(int(pid),0); alive=True
    except Exception:
        alive=False

# ocul publishes `by`; the upstream mux does not. when ocul owns the path the
# thing that rotates is the warp egress /64, not a webshare upstream — so pool
# counts, probing advice and the env shim all belong to a different machine.
ocul = st.get("by") == "ocul"

if ocul:
    listen = st.get("listen") or "127.0.0.1:40123"
    if up and not alive:
        print("    ! ocul lane says up but pid %s is gone — ocul proxy-on" % pid)
    elif alive:
        edge, _, egress = (st.get("current") or "").partition(" -> ")
        pfx = ident.get("prefix") or ""
        if not pfx and egress.count(":") >= 4:
            pfx = ":".join(egress.split(":")[:4])
        bits = ["ocul lane up on %s" % listen]
        if edge.strip(): bits.append("edge %s" % edge.strip())
        if pfx: bits.append("egress /64 %s" % pfx)
        bits.append("%s rotations" % st.get("rotations", 0))
        bits.append("%s served" % st.get("served", 0))
        print("    ✓ " + " · ".join(bits))
        if st.get("failed"):
            print("    ! %s request(s) failed through the lane — ocul overlay · ocul hop" % st.get("failed"))
        print("    · policy %s — only the pinned hosts ride the tunnel, everything else is direct"
              % (st.get("policy") or "strict"))
    else:
        print("    · ocul lane off (opt-in) — ocul proxy-on, or HUD → PROXY → ON")
else:
    if up and not alive:
        print("    ! proxy mux says up but pid %s is gone — HUD → PROXY → OFF then ON" % pid)
    elif alive:
        healthy=st.get("healthy",0); tested=st.get("tested",0)
        mark="✓" if healthy or not tested else "!"
        print("    %s proxy mux up on %s · %s of %s upstreams healthy · %s rotations · %s served" % (
            mark, st.get("listen") or "127.0.0.1:8899", healthy, pool,
            st.get("rotations",0), st.get("served",0)))
        if pool == 1:
            print("    ! one upstream: rotation cannot change your egress ip — proxy-pool import <file|url> takes a whole webshare list")
        if pool and tested==0:
            print("    ! nothing probed yet — a fresh mux cannot know the pool is good; HUD → PROXY → TEST")
        elif pool and healthy==0:
            print("    ! all %d probed upstream(s) are parked dead — that is the pool, not the mux" % tested)
    elif pool:
        print("    ! %d upstream(s) in the pool but the mux is down — HUD → PROXY → ON" % pool)
    else:
        print("    ✓ proxy layer off (opt-in) — HUD → PROXY to add webshare-style upstreams")

# the system toggle is a claim about the os, so check the os. pointing the
# machine at a stopped listener is not "routed through the mux", it is a dead
# internet with a green tick next to it. ocul never claims the system toggle.
if st.get("system") and not ocul:
    try:
        out=subprocess.run(["scutil","--proxy"],capture_output=True,text=True,timeout=5).stdout
    except Exception:
        out=""
    pointed = "127.0.0.1" in out and "8899" in out
    if pointed and alive:
        print("    ✓ system proxy → 127.0.0.1:8899 (every app routed through the mux)")
    elif pointed:
        print("    ✗ system proxy → 127.0.0.1:8899 but the mux is DOWN — every app is talking to a dead port. HUD → PROXY → OFF (or ON)")
    else:
        print("    ! system flag is set but macOS is not pointed at 127.0.0.1:8899 — HUD → PROXY → OFF then SYS")

# the shim makes an upstream-mux service born-proxied. ocul does not use it:
# ocul forces --standalone instead, which is checked at the bottom of this block.
if not ocul:
    try:
        tgt = os.path.realpath(os.path.expanduser("~/.npm-global/bin/opencode"))
        head = ""
        if os.path.exists(tgt):
            with open(tgt, "r", errors="replace") as f:
                head = "".join([next(f, "") for _ in range(3)])
        if "opencode shim" in head:
            print("    ✓ cli shim installed (every opencode process is born with the proxy env)")
        elif os.path.exists(tgt + ".real"):
            print("    ! cli shim removed — proxy-pool shim on reinstalls it")
    except Exception:
        pass

# the sockets belong to the CLI's `serve --service` child, which inherits env at
# spawn. ocul lane never attaches to that shared server — it starts a private
# one with --standalone — so the proof is in the launchers, not in a pid's env.
try:
    listing = subprocess.run(["ps", "-Ao", "pid=,args="],
                             capture_output=True, text=True, timeout=5).stdout
except Exception:
    listing = ""
pids = [ln.split(None, 1)[0] for ln in listing.splitlines()
        if "serve --service" in ln and "opencode" in ln]

if ocul:
    launchers = [("ocul lane", os.path.expanduser("~/.local/share/ocu-lane/ocul.py")),
                 ("zen-lane.sh", os.path.expanduser("~/.local/share/opencode-unlimited/scripts/zen-lane.sh"))]
    missing = []
    for name, path in launchers:
        try:
            body = open(path, errors="replace").read()
        except Exception:
            body = ""
        if "--standalone" not in body:
            missing.append(name)
    if missing:
        print("    ! %s no longer force --standalone — the private server would inherit the stale env" % ", ".join(missing))
    else:
        print("    ✓ ocul lane + zen-lane force --standalone (the private server is born with the proxy env)")
        if pids:
            print("    · legacy serve --service pid %s is shared and unproxied — the lane does not use it"
                  % pids[0])
elif pids:
    try:
        envout = subprocess.run(["ps", "eww", pids[0]], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        envout = ""
    uses = "HTTPS_PROXY=" in envout
    if uses and alive:
        print("    ✓ opencode service → 127.0.0.1:8899 (cli traffic rotated)")
    elif uses:
        print("    ✗ opencode service points at a stopped mux — restart the CLI, or HUD → PROXY → OFF")
    elif alive and up:
        print("    ! opencode service bypasses the mux — restart the CLI so it is born with the proxy env")
PY
# ---- free-model lever (the wall text itself says "or switch models")
python3 - "$HOME/.config/opencode/opencode.json" "$DEST/models.json" "$GUARD_DIR/models-used.json" <<'PY'
import json,sys
conf_p,cat_p,used_p=sys.argv[1:4]
cur=""
try:
    d=json.load(open(conf_p)); m=d.get("model")
    if isinstance(m,dict): m=m.get("model")
    # provider-qualified ids carry slashes ("9router/oc/big-pickle") and the
    # catalog keys on the leaf, so the leaf is what gets compared.
    if isinstance(m,str) and m.strip(): cur=m.strip().rsplit("/",1)[-1]
except Exception: pass
free=set()
try:
    cat=json.load(open(cat_p)).get("opencode") or {}
    for mid,mm in (cat.get("models") or {}).items():
        c=((mm.get("cost") or {}).get("text") or {})
        if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
           and mm.get("type") in ("chat","decision"):
            free.add(mid)
except Exception: pass
burned=[]
try: burned=json.load(open(used_p))
except Exception: pass
if not free:
    print("    ! model catalog not cached — HUD → PROXY → MODELS → REFRESH")
else:
    hot=[b for b in burned if b in free]
    if cur and cur in free:
        print("    ✓ default model is a free one: %s · %d of %d unburned" % (
            cur, len(free)-len(hot), len(free)))
    elif cur:
        print("    ! default model %s is not a zero-cost model — pick one in HUD → PROXY → MODELS" % cur)
    else:
        print("    ✓ no default model pinned — the CLI picks · %d free models available" % len(free))
    if hot:
        print("    · free models burned this run: %d (%s)" % (len(hot), ", ".join(hot[:3])))
PY
# the model lever keeps a dead cache; when most of the free pool is in it, the
# wall is account-side and no rotation will help. say it here, once.
python3 - "$GUARD_DIR/models-dead.json" "$DEST/models.json" <<'PY' 2>/dev/null
import json,os,sys,time
deadf,catf=sys.argv[1:3]
try: dead=json.load(open(deadf))
except Exception: dead={}
try: cat=json.load(open(catf))
except Exception: cat={}
free=0
for mid,m in ((cat.get("opencode") or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 and m.get("type")=="chat":
        free+=1
now=time.time()
live=[k for k,v in dead.items() if (now-float(v.get("ts") or 0)) < (1800 if str(v.get("code"))=="429" else 21600)]
if free and len(live) >= free:
    print("    ✗ every free model is walled or unavailable — the free pool is exhausted account-wide; key rotation cannot bypass it")
elif live:
    print("    ! %d of %d free models are walled/unavailable right now (model-levers probe)" % (len(live), free))
PY

# wall telemetry: how many walls, and did rotations ever clear one
python3 - "$GUARD_DIR/walls.jsonl" <<'PY' 2>/dev/null
import json,os,sys,time
p=sys.argv[1]
if not os.path.exists(p):
    print("    · no walls recorded yet — guard/walls.jsonl starts on the next one")
    raise SystemExit
try: ev=[json.loads(l) for l in open(p) if l.strip()]
except Exception: ev=[]
det=[e for e in ev if e.get("what")=="detected"]; land=[e for e in ev if e.get("what")=="landed"]
if det:
    if land:
        bad=sum(1 for l in land if any(0 <= d["ts"]-l["ts"] <= 600 for d in det))
        print("    · walls recorded: %d · landings: %d · landings walled again in 10 min: %d" % (len(det), len(land), bad))
        if len(land)>=3 and bad*2>=len(land):
            print("    ! rotations are not clearing this wall — model/provider levers first (wall-report.sh)")
    else:
        print("    · walls recorded: %d · no landings logged yet (a landing is written when a rotated lane gets through)" % len(det))
PY

# ---- credit system (AGENTS.md) — opt-in, off by default
if [ "${OUC_CREDIT:-0}" = "1" ]; then
  [ -f "$HOME/.opencode/AGENTS.md" ] \
    && ok "credit file ~/.opencode/AGENTS.md present (every AI response signs off)" \
    || warn "credit file missing — cp $DEST/AGENTS.md ~/.opencode/AGENTS.md"
else
  ok "credit stamp off (third-party sign-off injection disabled; OUC_CREDIT=1 re-enables)"
fi

echo ""
echo "  all good = work. something red = run the command next to it."
echo ""
