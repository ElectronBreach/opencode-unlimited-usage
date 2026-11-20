#!/bin/bash
# status — machine-readable snapshot of the whole system, for the overlay.
#
#   status.sh            cached (network probes at most every STATUS_TTL s)
#   status.sh --force    refresh network probes now
#   status.sh --raw      plain text one-liner (for shell prompts / scripts)
#
# local state (guard json, launchd, sqlite) is read every call — it is cheap.
# only the network probes (egress, dns) are cached, because a 2-second UI
# refresh must not put 30 curl calls a minute through the tunnel.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD="$DEST/guard"
STATE="$GUARD/state.json"
CACHE="$GUARD/status-cache.json"
DB="$HOME/.local/share/opencode/opencode.db"
# the macOS port keeps its own state; prefer it and fall back to the legacy
# guard directory only when the new engine has never written anything.
OUC_APP="$HOME/Library/Application Support/opencode-unlimited"
OUC_STATE="$OUC_APP/state.json"
OUC_BLACKLIST="$OUC_APP/blacklist.json"
OUC_HISTORY="$OUC_APP/history.jsonl"
OUC_HOP_LOG="$OUC_APP/logs/hop.log"
TTL="${OUC_STATUS_TTL:-15}"
FORCE=0
RAW=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --raw)   RAW=1 ;;
  esac
done

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/local/bin/warp-cli ]; then WARP=/usr/local/bin/warp-cli
  elif [ -x /opt/homebrew/bin/warp-cli ]; then WARP=/opt/homebrew/bin/warp-cli
  elif [ -x "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" ]; then WARP="/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
  fi
fi
wo(){ [ -n "$WARP" ] || return 1; sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

now=$(date +%s)

# ---- the brain ------------------------------------------------------------
# The guard publishes everything that needs a subprocess or a network probe:
# warp status and mode, guard/keeper liveness, the exit /64 and how old its
# measurement is, proxy health, the in-flight rotation and a heartbeat.
#
# When that file is fresh this script stops calling `warp-cli` twice through
# sudo, stops calling `launchctl print` four times, and stops curling — the
# two-second refresh becomes a few local reads instead of a process tree. When
# it is stale or missing, every old path below runs exactly as before, so the
# HUD can never be left blank by a guard that is not there.
BRAIN="$GUARD/brain.json"
BRAIN_OK=0
BRAIN_SEQ=0; BRAIN_SCORE=-1; BRAIN_STATE=""; BRAIN_ADVICE=0
ROT_ACTIVE=0; ROT_PHASE=""; ROT_ATTEMPT=0; ROT_MAX=0
if [ -f "$BRAIN" ]; then
  eval "$(python3 - "$BRAIN" "$now" <<'PY' 2>/dev/null
import json, sys
try:
    b = json.load(open(sys.argv[1]))
except Exception:
    b = {}
if not isinstance(b, dict):
    b = {}
now = int(sys.argv[2])
def q(v):
    return "'" + str(v if v is not None else "").replace("'", "") + "'"
def n(v):
    try: return int(v)
    except Exception: return 0
try:
    age = max(0, now - int(b.get("beat") or 0))
except Exception:
    age = 10 ** 6
# a brain older than its freshness window is not a snapshot, it is a fossil.
if age > 20 or n(b.get("v")) != 1:
    print("BRAIN_OK=0")
    raise SystemExit(0)
eg = b.get("egress") or {}
# a rotation in progress is a fact the panel must show: HOP looks clickable
# while the rotator owns the tunnel, and clicking it answers "rotation already
# in progress" — a button that lies about its own availability.
r = b.get("rotation") or {}
print("ROT_ACTIVE=%d" % (1 if r.get("active") else 0))
print("ROT_PHASE=%s" % q(r.get("phase")))
print("ROT_ATTEMPT=%d" % n(r.get("attempt")))
print("ROT_MAX=%d" % n(r.get("max")))
w = b.get("warp") or {}
g = b.get("guard") or {}
k = b.get("keeper") or {}
sn = b.get("sensors") or {}
h = b.get("health") or {}
eage = max(0, min(10 ** 6, now - n(eg.get("at"))))
print("BRAIN_OK=1")
print("BRAIN_SEQ=%d" % n(b.get("seq")))
print("BRAIN_SCORE=%d" % (n(h.get("score")) if h else -1))
print("BRAIN_STATE=%s" % q(h.get("state")))
print("BRAIN_ADVICE=%d" % len(b.get("advice") or []))
print("c_ip=%s" % q(eg.get("ip")))
print("c_ts=%d" % (now - eage))
print("c_dns=%d" % (1 if sn.get("dns") else 0))
print("c_dev=%s" % q((b.get("tunnel") or {}).get("device") or ""))
print("c_fail=0")
print("tunnel=%d" % (1 if w.get("connected") else 0))
print("mode=%s" % q(w.get("mode")))
print("keeper=%d" % (1 if k.get("running") else 0))
print("guard=%d" % (1 if g.get("running") else 0))
# the guard heartbeat. it is the only stamp that moves on every tick,
# including the ticks where nothing else changed.
# NOTE: keep this comment free of apostrophes. The HUD runs this file with
# /bin/bash (3.2), whose parser mis-counts a lone quote inside a here-doc
# that sits in $( ), bleeding to EOF and killing the whole snapshot.
print("BRAIN_BEAT=%d" % n(b.get("beat")))
PY
)"
fi


# ---- cached network probes ------------------------------------------------
# A failed probe must back off. The old test re-probed on every call the moment
# the egress field was empty, so an offline machine ran two curls plus a dig
# every two seconds and the Swift 12s watchdog started killing status.sh
# mid-flight — the HUD froze for reasons that had nothing to do with the lane.
PROBE_RETRY="${OUC_PROBE_RETRY:-20}"   # seconds to wait after a failed probe
# when the brain answered, these are already populated. defaulting them here
# unconditionally is what blanked a fresh exit one line after reading it.
if [ "$BRAIN_OK" != "1" ]; then
  c_ts=0; c_ip=""; c_dns=0; c_dev=""; c_fail=0
fi
c_ts="${c_ts:-0}"; c_ip="${c_ip:-}"; c_dns="${c_dns:-0}"
c_dev="${c_dev:-}"; c_fail="${c_fail:-0}"
if [ -f "$CACHE" ] && [ "$BRAIN_OK" != "1" ]; then
  eval "$(python3 - "$CACHE" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
if not isinstance(d, dict): d={}
def s(v): return ("'" + str(v or "").replace("'","") + "'")
print("c_ts=%d" % int(d.get("ts") or 0))
print("c_ip=%s" % s(d.get("egress4")))
print("c_dns=%d" % (1 if d.get("dns") else 0))
print("c_dev=%s" % s(d.get("device")))
print("c_fail=%d" % int(d.get("fail") or 0))
PY
)"
fi
net_age=$(( now - c_ts ))
# a clock step backwards (ntp correction, manual set) makes now-c_ts negative.
# treating that as "fresh" would trust a stamp from the future forever.
[ "$net_age" -lt 0 ] && net_age=999999
probe=0
[ "$FORCE" = "1" ] && probe=1
[ "$net_age" -gt "$TTL" ] && probe=1
# empty egress + fresh stamp = the last probe failed. retry on the backoff.
[ -z "$c_ip" ] && [ "$net_age" -gt "$PROBE_RETRY" ] && probe=1
probe_ok=0
if [ "$probe" = "1" ] && [ "$BRAIN_OK" != "1" ]; then
  p_ip=$(curl -4 -s -m 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
  [ -n "$p_ip" ] || p_ip=$(curl -4 -s -m 2 https://api64.ipify.org 2>/dev/null)
  if [ -n "$p_ip" ]; then c_ip="$p_ip"; probe_ok=1; c_fail=0; else c_fail=$((c_fail + 1)); fi
  if [ -n "$(dig +short +time=1 +tries=1 opencode.ai 2>/dev/null)" ]; then c_dns=1; else c_dns=0; fi
  c_ts=$now
  # the device id changes on every re-registration, and a rotation is exactly
  # what this stack does, so it is refreshed with the probes instead of being
  # cached forever.
  c_dev=$("$WARP" --accept-tos registration show 2>/dev/null | awk -F': ' '/^Device ID:/{print $2; exit}')
  [ -n "$c_dev" ] || c_dev=$("$WARP" --accept-tos registration show 2>/dev/null | awk '/^ID:/{print $2; exit}')
  printf '{"ts":%d,"egress4":"%s","dns":%d,"device":"%s","ok":%d,"fail":%d}\n' \
    "$c_ts" "${c_ip:-}" "$c_dns" "${c_dev:-}" "$probe_ok" "$c_fail" > "$CACHE.tmp" 2>/dev/null \
    && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
else
  [ "$c_fail" -gt 0 ] && [ "$net_age" -gt "$TTL" ] && probe_ok=0 || probe_ok=$([ -n "$c_ip" ] && echo 1 || echo 0)
  if [ -z "$c_dev" ] && [ "$BRAIN_OK" != "1" ]; then
    c_dev=$("$WARP" --accept-tos registration show 2>/dev/null | awk -F': ' '/^Device ID:/{print $2; exit}')
    [ -n "$c_dev" ] || c_dev=$("$WARP" --accept-tos registration show 2>/dev/null | awk '/^ID:/{print $2; exit}')
  fi
fi
probe_age=$(( now - c_ts ))
[ "$probe_age" -lt 0 ] && probe_age=999999

# ---- local state ----------------------------------------------------------
# only ask warp-cli and launchd when the brain could not answer. four forks and
# two sudo calls per refresh is the whole cost this file used to pay for a
# snapshot the guard had already written.
if [ "$BRAIN_OK" != "1" ]; then
  tunnel=0; mode=""
  if [ -n "$WARP" ]; then
    wo status 2>/dev/null | head -1 | grep -q Connected && tunnel=1
    mode=$(wo settings 2>/dev/null | awk -F'Mode: ' '/Mode:/{print $2; exit}')
  fi
  keeper=0; launchctl print "gui/$(id -u)/com.ouc.keeper" >/dev/null 2>&1 && keeper=1
  [ "$keeper" = "1" ] || { launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1 && keeper=1; }
  guard=0;  launchctl print "gui/$(id -u)/ai.ocul.guard" >/dev/null 2>&1 && guard=1
  [ "$guard" = "1" ]  || { launchctl print "gui/$(id -u)/com.ouc.guard" >/dev/null 2>&1 && guard=1; }
  [ "$guard" = "1" ]  || { launchctl print "gui/$(id -u)/com.opencode-unlimited.guard" >/dev/null 2>&1 && guard=1; }
fi
# the credit stamp is opt-in (OUC_CREDIT=1). it is off by design, so the chip
# must read idle rather than failed when the stamp file is simply absent.
credit=0; [ "${OUC_CREDIT:-0}" = "1" ] && [ -f "$HOME/.opencode/AGENTS.md" ] && credit=1
leak="off"
if [ -f /etc/pf.anchors/OUC_LEAKGUARD ]; then
  r=$(sudo -n /sbin/pfctl -a OUC_LEAKGUARD -s rules 2>/dev/null | grep -c .)
  if [ "${r:-0}" -gt 0 ]; then leak="armed ($r)"; else leak="installed/empty"; fi
fi

# project context written by the lane when opencode launches
ctx_dir=""; ctx_ts=0
if [ -f "$GUARD/overlay-context.json" ]; then
  eval "$(python3 - "$GUARD/overlay-context.json" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print("ctx_dir=%s" % ("'" + str(d.get("dir") or "").replace("'","") + "'"))
print("ctx_ts=%d" % int(d.get("ts") or 0))
PY
)"
fi

# ocul mirrors a `guard_ts` heartbeat into the App Support state every tick, so
# the age of that stamp is the only honest signal that separates an idle-but-
# healthy rotator from a wedged one. A launchd "running" chip alone painted a
# hung guard green.

export OUC_NOW="$now" OUC_IP="${c_ip:-}" OUC_DNS="$c_dns" OUC_TUNNEL="$tunnel" \
       OUC_MODE="$mode" OUC_KEEPER="$keeper" OUC_GUARD="$guard" OUC_CREDIT="$credit" \
       OUC_LEAK="$leak" OUC_STATE="$STATE" OUC_LEDGER="$GUARD/identities.json" OUC_DB="$DB" OUC_CTX_DIR="$ctx_dir" \
       OUC_CTX_TS="$ctx_ts" OUC_BRAND="$BRAND" OUC_DEST="$DEST" \
       OUC_NEW_STATE="$OUC_STATE" OUC_NEW_BLACKLIST="$OUC_BLACKLIST" \
       OUC_NEW_HISTORY="$OUC_HISTORY" OUC_NEW_HOPLOG="$OUC_HOP_LOG" OUC_DEVICE="${c_dev:-}" \
       OUC_PROBE_OK="$probe_ok" OUC_PROBE_AGE="$probe_age" OUC_LADDER="$GUARD/ladder.json" \
       OUC_BRAIN_SEQ="$BRAIN_SEQ" OUC_BRAIN_SCORE="$BRAIN_SCORE" \
       OUC_BRAIN_STATE="$BRAIN_STATE" OUC_BRAIN_ADVICE="$BRAIN_ADVICE" OUC_BRAIN_OK="$BRAIN_OK" \
       OUC_BRAIN_BEAT="${BRAIN_BEAT:-0}" \
       OUC_ROT_ACTIVE="$ROT_ACTIVE" OUC_ROT_PHASE="$ROT_PHASE" \
       OUC_ROT_ATTEMPT="$ROT_ATTEMPT" OUC_ROT_MAX="$ROT_MAX"

python3 - <<'PY'
import json, os, sqlite3, time, datetime, hashlib

def env(k, d=""):
    return os.environ.get(k, d)

def num(x, d=0):
    try: return int(x)
    except Exception: return d

now = num(env("OUC_NOW"), int(time.time()))
out = {
    "ts": now,
    "warp": {"connected": env("OUC_TUNNEL") == "1", "mode": env("OUC_MODE")},
    "keeper": env("OUC_KEEPER") == "1",
    "guard": env("OUC_GUARD") == "1",
    # age of the rotator's own heartbeat (seconds). -1 = never seen. filled in
    # below once the App Support state is loaded.
    "guardAge": -1,
    # was the last egress probe a success, and how old is it. lets the panel say
    # "cached exit" instead of presenting a stale address as live.
    "probe": {"ok": env("OUC_PROBE_OK") == "1", "age": num(env("OUC_PROBE_AGE"), -1)},
    # which models actually answer right now, and which one the CLI is pinned
    # to. a pin is not a fact — it is a guess with a timestamp.
    "ladder": {"best": None, "live": 0, "age": -1, "wall": 0},
    "dns": env("OUC_DNS") == "1",
    "credit": env("OUC_CREDIT") == "1",
    "leakguard": env("OUC_LEAK"),
    "egress4": env("OUC_IP"),
    "context": {"dir": env("OUC_CTX_DIR"), "age": (now - num(env("OUC_CTX_TS"))) if env("OUC_CTX_TS") else -1},
    # the guard's own document. additive, so every existing chip keeps working;
    # a reader that wants one health number reads it here instead of deriving
    # its own from five fields and disagreeing with the next reader.
    "rotation": {"active": env("OUC_ROT_ACTIVE") == "1",
                 "phase": env("OUC_ROT_PHASE"),
                 "attempt": num(env("OUC_ROT_ATTEMPT")),
                 "max": num(env("OUC_ROT_MAX"))},
    "brain": {"live": env("OUC_BRAIN_OK") == "1",
              "seq": num(env("OUC_BRAIN_SEQ")),
              "score": num(env("OUC_BRAIN_SCORE"), -1),
              "state": env("OUC_BRAIN_STATE"),
              "advice": num(env("OUC_BRAIN_ADVICE"))},
}

# ---- guard state
st = {}
try:
    with open(env("OUC_STATE")) as f:
        st = json.load(f)
except Exception:
    pass
if not isinstance(st, dict):
    st = {}

# the macOS port writes its own state + a separate blacklist file. when that
# state exists it is the truth; the legacy guard json is only a fallback for a
# machine that has not migrated yet.
new = {}
try:
    with open(env("OUC_NEW_STATE")) as f:
        new = json.load(f)
except Exception:
    pass
if not isinstance(new, dict):
    new = {}
# ocul writes this stamp on every tick; its age is the rotator's heartbeat.
try:
    _gts = float(new.get("guard_ts") or 0)
except Exception:
    _gts = 0.0
# a live brain beats any other guard stamp: `beat` moves every tick, while
# guard_ts is written by the HUD publisher and can lag a rotation.
_bbeat = 0
try:
    _bbeat = int(env("OUC_BRAIN_BEAT") or 0)
except Exception:
    _bbeat = 0
if env("OUC_BRAIN_OK") == "1" and _bbeat > 0:
    out["guardAge"] = max(0, int(now - _bbeat))
elif _gts > 0:
    out["guardAge"] = max(0, int(now - _gts))
blocks = []
try:
    with open(env("OUC_NEW_BLACKLIST")) as f:
        _bl = json.load(f)
    if isinstance(_bl, dict):
        blocks = [b for b in (_bl.get("blocks") or []) if b]
    elif isinstance(_bl, list):
        blocks = [b for b in _bl if b]
except Exception:
    pass
legacy_blocks = [x for x in (st.get("blacklist") or []) if x]
known = blocks or legacy_blocks

# ocul is the canonical rotator on this machine. its guard.json carries the
# live egress /64 (the bucket the quota is keyed on) and the real hop count.
# the App Support state.json is only written by the retired `ouc` engine, so
# preferring it froze the HUD tile at whatever ouc last wrote — the rotation
# happened, the panel kept showing the previous block.
ocul = {}
try:
    with open(os.path.expanduser("~/.local/state/ocu-lane/guard.json")) as f:
        ocul = json.load(f)
except Exception:
    pass
if not isinstance(ocul, dict):
    ocul = {}

prefix = (ocul.get("egress_prefix") or new.get("current_64") or st.get("prefix") or "").strip()
hist_total = 0
try:
    with open(env("OUC_NEW_HISTORY")) as f:
        for line in f:
            if '"ok": true' in line:
                hist_total += 1
except Exception:
    pass
if ocul.get("last_hop"):
    hops = num(ocul.get("hops"))
else:
    hops = hist_total or (num(new.get("hops")) if new else num(st.get("hops")))
# rot must exist before device reads it. it used to be defined a line below,
# so an empty OUC_DEVICE (warp-cli registration show failing) evaluated
# rot.get(...) on an undefined name and threw the whole status JSON away —
# which the HUD renders as a silent freeze, not an error.
rot = new.get("last_rotation") if isinstance(new.get("last_rotation"), dict) else {}
device = (env("OUC_DEVICE") or rot.get("new_device") or st.get("device") or "").strip()
# the live hop stamp: ocul is canonical, the retired App Support state is the
# fallback. reading legacy alone froze "LAST" at whatever `ouc` last wrote.
last_hop = 0.0
for cand in (ocul.get("last_hop"), new.get("last_hop"), st.get("last_hop")):
    try:
        v = float(cand or 0)
    except Exception:
        v = 0.0
    if v > 0:
        last_hop = v
        break

out["identity"] = {
    # `current` is the label the HUD prints as "where we are". the /64 is the
    # bucket; a v4-only network shows its exit v4 because that is what the
    # server actually sees.
    "current": prefix or st.get("current") or "",
    "prefix": prefix,
    "seen6": ocul.get("egress") or new.get("egress") or new.get("current_64") or st.get("seen6") or "",
    "device": device[:8],
    "hops": hops,
    "blacklist": len(known),
    # the bucket is the quota key. burnt is the honest answer to "have we
    # already been walled on this one", which is what the HUD has to show.
    "bucket": prefix,
    "burnt": bool(prefix and prefix in known),
    # a v4 only goes in this field if it is actually a v4. `OUC_IP` is the
    # egress the brain measured, and measure_egress only ever accepts an
    # address with a colon — so falling back to it put a v6 under a v4 label.
    "v4": (lambda v: v if ("." in v and ":" not in v) else "")(
        new.get("current_v4") or ""),
    "since": int(max(0, now - last_hop)) if last_hop else -1,
    # a hop stamp in the future is a park, not a rotation. the panel shows the
    # countdown instead of lying "0s ago" while rotation is deliberately held.
    "parked": int(max(0, last_hop - now)) if last_hop and last_hop > now else 0,
    "guardAge": out["guardAge"],
    "kind": rot.get("kind") or "",
    "v4Changed": bool(rot.get("v4_changed")),
    "failStreak": num(new.get("fail_streak")),
    "retryIn": int(max(0, float(new.get("next_retry_ts") or 0) - now)) if new.get("next_retry_ts") else 0,
    "engine": "ouc" if new else "legacy",
    "bucketWalls": 0, "bucketHops": 0,
}
try:
    with open(env("OUC_LEDGER")) as f:
        led = json.load(f).get("buckets", {})
    e = led.get(prefix or st.get("prefix") or "", {}) or {}
    out["identity"]["bucketWalls"] = num(e.get("walls"))
    out["identity"]["bucketHops"] = num(e.get("hops"))
except Exception:
    pass

# ---- tokens (opencode.db, read-only; WAL is active so never copy the file)
#
# opencode keeps one row per session and no per-message ledger, so every number
# here is a session total. the parts are kept separate rather than pre-added:
# cache reads outnumber real tokens by two orders of magnitude, and folding them
# into one "tokens" figure makes the headline meaningless.
#
#   input / output / reasoning      what the model actually read and wrote
#   cacheRead / cacheWrite          prompt cache traffic (cheap, but real work)
#   total                           input + output          — the headline
#   billed                          input + output + reasoning
#   cacheHit                        cacheRead / (cacheRead + input)
#   activeSec                       time_busy summed, i.e. time the model ran
#   subagents                       sessions with a parent — spawned, not typed
tok = {
    "db": False, "sessions": 0, "allSessions": 0, "subagents": 0,
    "input": 0, "output": 0, "reasoning": 0,
    "cacheRead": 0, "cacheWrite": 0,
    "total": 0, "billed": 0, "cacheHit": 0.0, "cost": 0.0, "activeSec": 0,
    "today": {"sessions": 0, "input": 0, "output": 0, "reasoning": 0,
              "cacheRead": 0, "total": 0, "cost": 0.0},
    "week": [], "last": None, "recent": [], "models": [],
}
db = env("OUC_DB")
if os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
        con.row_factory = sqlite3.Row
        c = con.cursor()
        r = c.execute("""SELECT COUNT(*) n,
                                SUM(CASE WHEN parent_id IS NULL THEN 1 ELSE 0 END) roots,
                                COALESCE(SUM(tokens_input),0) ti,
                                COALESCE(SUM(tokens_output),0) to_,
                                COALESCE(SUM(tokens_reasoning),0) tr,
                                COALESCE(SUM(tokens_cache_read),0) tcr,
                                COALESCE(SUM(tokens_cache_write),0) tcw,
                                COALESCE(SUM(cost),0) cost,
                                COALESCE(SUM(CASE WHEN time_busy > time_created
                                                  THEN time_busy - time_created ELSE 0 END),0) span
                         FROM session_v2""").fetchone()
        ti, to_, tr = int(r["ti"]), int(r["to_"]), int(r["tr"])
        tcr, tcw = int(r["tcr"]), int(r["tcw"])
        denom = tcr + ti
        tok.update({
            "db": True,
            "sessions": int(r["roots"] or 0),
            "allSessions": int(r["n"] or 0),
            "subagents": int((r["n"] or 0) - (r["roots"] or 0)),
            "input": ti, "output": to_, "reasoning": tr,
            "cacheRead": tcr, "cacheWrite": tcw,
            "total": ti + to_, "billed": ti + to_ + tr,
            "cacheHit": round(tcr / denom, 4) if denom else 0.0,
            "cost": round(r["cost"] or 0, 4),
            # time_busy is an epoch, not a duration. summing it produced a
            # number in the tens of billions. the span from create to last
            # activity is the only hours figure the schema actually carries.
            "activeSec": int((r["span"] or 0) / 1000),
        })

        # today: sessions that did work since local midnight. a session that
        # started last week counts here if it is still being used — the tokens
        # are still that session's lifetime, so this is a "touched today" view,
        # not a slice of today's spend. it is labelled that way in the HUD.
        # sqlite's 'localtime' and python's disagree on this box, so the day
        # boundaries are computed once, here, and passed in as epochs.
        today0 = int(datetime.datetime.combine(datetime.date.today(),
                                               datetime.time.min).timestamp())
        r = c.execute("""SELECT COUNT(*) n,
                                COALESCE(SUM(tokens_input),0) ti,
                                COALESCE(SUM(tokens_output),0) to_,
                                COALESCE(SUM(tokens_reasoning),0) tr,
                                COALESCE(SUM(tokens_cache_read),0) tcr,
                                COALESCE(SUM(cost),0) cost
                         FROM session_v2
                         WHERE time_busy >= ?""", (today0 * 1000,)).fetchone()
        tok["today"] = {
            "sessions": int(r["n"] or 0),
            "input": int(r["ti"] or 0), "output": int(r["to_"] or 0),
            "reasoning": int(r["tr"] or 0), "cacheRead": int(r["tcr"] or 0),
            "total": int((r["ti"] or 0) + (r["to_"] or 0)),
            "cost": round(r["cost"] or 0, 4),
        }

        # last 7 days by the day the session started — the only per-day cut the
        # schema supports without a message ledger. bucketed in python because
        # the SQL boundary compared an INTEGER column to a TEXT strftime and
        # every row lost, leaving the chart flat zero.
        week0 = today0 - 6 * 86400
        rows = c.execute("""SELECT time_created, tokens_input, tokens_output, cost
                            FROM session_v2
                            WHERE time_created >= ?""", (week0 * 1000,)).fetchall()
        days = {}
        for row in rows:
            d = datetime.datetime.fromtimestamp(int(row["time_created"]) / 1000).date()
            e = days.setdefault(d, {"total": 0, "cost": 0.0, "sessions": 0})
            e["total"] += int(row["tokens_input"] or 0) + int(row["tokens_output"] or 0)
            e["cost"] += row["cost"] or 0
            e["sessions"] += 1
        week = []
        for i in range(6, -1, -1):
            day = datetime.date.today() - datetime.timedelta(days=i)
            e = days.get(day) or {"total": 0, "cost": 0.0, "sessions": 0}
            week.append({
                "date": day.strftime("%Y-%m-%d"),
                "label": day.strftime("%a"),
                "total": e["total"],
                "cost": round(e["cost"], 4),
                "sessions": e["sessions"],
            })
        tok["week"] = week

        def model_name(m):
            m = m or ""
            try:
                j = json.loads(m)
            except Exception:
                return m
            # the variant is a setting, not a different model. without this the
            # same model splits across rows and the top-4 list lies.
            n = j.get("id") or j.get("modelID") or m
            return "%s/%s" % (j["providerID"], n) if j.get("providerID") else n

        # 24 rows because the burn chart draws 24; it used to ask for 12 and
        # label the chart "last 24".
        rows = c.execute("""SELECT title, tokens_input, tokens_output, tokens_reasoning,
                                   tokens_cache_read, cost, model, time_updated, directory
                            FROM session_v2 ORDER BY time_updated DESC LIMIT 24""").fetchall()
        for i, row in enumerate(rows):
            d = dict(row)
            item = {
                "title": (d.get("title") or "untitled")[:64],
                "input": int(d.get("tokens_input") or 0),
                "output": int(d.get("tokens_output") or 0),
                "reasoning": int(d.get("tokens_reasoning") or 0),
                "cacheRead": int(d.get("tokens_cache_read") or 0),
                "tokens": int(d.get("tokens_input") or 0) + int(d.get("tokens_output") or 0),
                "cost": round(d.get("cost") or 0, 4),
                "model": model_name(d.get("model")),
                "dir": (d.get("directory") or "").rsplit("/", 1)[-1],
                "age": max(0, now - int((d.get("time_updated") or 0) / 1000)),
            }
            if i == 0:
                tok["last"] = item
            tok["recent"].append(item)

        rows = c.execute("""SELECT model, COUNT(*) AS n,
                                   SUM(tokens_input+tokens_output) AS tok,
                                   SUM(tokens_cache_read) AS cache,
                                   SUM(cost) AS cost
                            FROM session_v2 GROUP BY model""").fetchall()
        agg = {}
        for row in rows:
            d = dict(row)
            name = model_name(d.get("model"))
            a = agg.setdefault(name, {"name": name, "sessions": 0, "tokens": 0,
                                      "cacheRead": 0, "cost": 0.0})
            a["sessions"] += int(d.get("n") or 0)
            a["tokens"] += int(d.get("tok") or 0)
            a["cacheRead"] += int(d.get("cache") or 0)
            a["cost"] += d.get("cost") or 0
        tok["models"] = sorted(agg.values(), key=lambda x: x["tokens"], reverse=True)[:4]
        for m in tok["models"]:
            m["cost"] = round(m["cost"], 4)
        con.close()
    except Exception as e:
        tok["error"] = str(e)[:200]
out["tokens"] = tok

# ---- opencode console key pool (the same credential table `opencode auth
# list` reads). one row is active; that is the key the CLI authenticates with.
keys = {"count": 0, "cap": num(env("OUC_KEY_CAP"), 50), "active": None,
        "activeMasked": None, "activeId": None, "keys": [],
        "live": 0, "dead": 0, "unknown": 0, "activeLive": None,
        "activeState": "unknown"}

# the console rejects a revoked key instantly, and a ten-minute "live" cache is
# how nine 401s still painted a green dot. a verdict counts as live only while
# it is younger than the same 60s window api-keys.sh trusts.
PROBE = os.path.join(os.path.expanduser("~/.local/share/opencode-unlimited/guard"),
                     "key-probe.json")
try:
    probes = json.load(open(PROBE))
except Exception:
    probes = {}

def key_verdict(raw):
    if not raw:
        return "unknown"
    e = probes.get(hashlib.sha256(raw.encode()).hexdigest()[:16])
    if not e:
        return "unknown"
    try:
        age = time.time() - float(e.get("ts") or 0)
    except Exception:
        return "unknown"
    st = e.get("st")
    if st == 0 and age < 60:
        return "live"
    if st == 1:
        return "dead"
    return "unknown"
if os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
        rows = con.execute("""SELECT id, label, value, COALESCE(active,0) a, time_created
                              FROM credential WHERE integration_id='opencode'
                              ORDER BY time_created ASC, id ASC""").fetchall()
        for cid, label, value, active, created in rows:
            try:
                k = json.loads(value).get("key", "")
            except Exception:
                k = ""
            masked = (k[:14] + "\u2026" + k[-4:]) if len(k) > 18 else (k[:4] + "\u2026" if k else "")
            item = {"id": cid, "label": label, "masked": masked,
                    "active": active == 1, "created": created or 0,
                    "state": key_verdict(k)}
            keys["keys"].append(item)
            if item["state"] == "live":
                keys["live"] += 1
            elif item["state"] == "dead":
                keys["dead"] += 1
            else:
                keys["unknown"] += 1
            if item["active"]:
                keys.update(active=label, activeMasked=masked, activeId=cid,
                            activeLive=(item["state"] == "live"),
                            activeState=item["state"])
        keys["count"] = len(keys["keys"])
        con.close()
    except Exception as e:
        keys["error"] = str(e)[:200]
out["apiKeys"] = keys

# ---- custom proxy layer — the second egress lever. WARP moves the /64; the
# mux moves the upstream behind one fixed local address. the HUD only needs
# four facts: is it up, how many exits are left, which one is current, and
# whether the machine-wide switch is on. a stale state file from a mux that
# died must read as down, so the pid is checked, not trusted.
px = {"up": False, "pool": 0, "healthy": 0, "current": None, "index": -1,
      "rotations": 0, "served": 0, "failed": 0, "system": False,
      "listen": "127.0.0.1:8899", "policy": "conn", "static": 0, "source": "",
      "age": 0, "stale": False}
try:
    gdir = os.path.dirname(PROBE)
    with open(os.path.join(gdir, "proxy-state.json")) as f:
        st = json.load(f)
    alive = False
    try:
        pid = int(st.get("pid") or 0)
        if pid > 0:
            os.kill(pid, 0)
            alive = True
    except Exception:
        alive = False
    px.update({k: st.get(k, px[k]) for k in px if k in st})
    px["up"] = bool(st.get("up")) and alive
    # a live pid proves the process exists, not that it is moving. ocul rewrites
    # this file every publish cycle, so a state file older than 90s is a wedged
    # mux — the same shape as a dead status.sh painted as a live panel.
    try:
        px["age"] = max(0, int(time.time()) - int(st.get("ts") or 0))
    except Exception:
        px["age"] = 999
    px["stale"] = px["age"] > 90
    if not px["up"]:
        px["current"] = None
    px["system"] = bool(st.get("system")) and px["up"]
except Exception:
    pass

# proxies.txt is the legacy static pool. ocul's mux reports its own pool in
# proxy-state.json (one upstream: the tunnel), so an absent or empty file must
# not zero a mux that is up and serving. the static file wins only when it
# actually lists an exit — otherwise it is a fossil, and the chip read "empty"
# on a mux with 2k requests behind it.
pool_file = os.path.normpath(os.path.join(os.path.dirname(PROBE), "..", "proxies.txt"))
static = 0
try:
    with open(pool_file) as f:
        static = sum(1 for l in f if l.strip() and not l.lstrip().startswith("#"))
except Exception:
    static = 0
px["pool"] = static if static else (px.get("pool") or 0)
px["static"] = static
px["source"] = "proxies.txt" if static else (px.get("source") or "mux")
if not px["pool"] or not px["up"]:
    px["healthy"] = 0
else:
    px["healthy"] = min(px.get("healthy") or px["pool"], px["pool"])
out["proxy"] = px

# ---- free-model lever. the wall text says "or switch models", and there are
# 51 zero-cost chat models on the opencode provider, so the cheapest bypass is
# a model switch: no tunnel, no dns window, no registration. only three small
# files are read here — the 10MB catalog is never touched in this path.
md = {"current": "", "burned": 0, "free": 0}
try:
    with open(os.path.expanduser("~/.config/opencode/opencode.json")) as f:
        conf = json.load(f)
    mm = conf.get("model")
    if isinstance(mm, str):
        md["current"] = mm.split("/", 1)[1] if "/" in mm else mm
    elif isinstance(mm, dict):
        md["current"] = mm.get("model") or ""
except Exception:
    pass
try:
    with open(os.path.join(os.path.dirname(PROBE), "models-used.json")) as f:
        md["burned"] = len(json.load(f))
except Exception:
    pass
try:
    with open(os.path.expanduser("~/.local/share/opencode-unlimited/models.json")) as f:
        cat = json.load(f)
    p = cat.get("opencode") or {}
    md["free"] = sum(1 for m in (p.get("models") or {}).values()
                     if (((m.get("cost") or {}).get("text") or {}).get("output") or {}).get("price") == 0
                     and (((m.get("cost") or {}).get("text") or {}).get("input") or {}).get("price") == 0
                     and m.get("type") in ("chat", "decision"))
except Exception:
    pass
# the ladder's last measurement. `free` counts how many models exist; this
# says how many actually answered — the number that decides the next prompt.
try:
    ladder = os.path.join(os.path.expanduser("~"), ".local/share/opencode-unlimited/guard/ladder.json")
    with open(ladder) as f:
        lad = json.load(f)
    live = [r for r in (lad.get("rows") or []) if r.get("state") == "live"]
    md["ladder"] = {
        "best": lad.get("best"),
        "live": len(live),
        "probed": len(lad.get("rows") or []),
        "age": int(time.time()) - int(lad.get("at") or 0),
    }
except Exception:
    md["ladder"] = {"best": None, "live": 0, "probed": 0, "age": -1}
out["model"] = md

# the ladder is the only truthful answer to "will the next prompt work?".
# rows are written by model-ladder.sh in one atomic replace, so a half read
# cannot happen; a missing file means no scan has run, which is not an error.
try:
    with open(env("OUC_LADDER")) as f:
        lad = json.load(f)
    rows = lad.get("rows") or []
    out["ladder"] = {
        "best": lad.get("best"),
        "live": sum(1 for r in rows if r.get("state") == "live"),
        "wall": sum(1 for r in rows if r.get("state") == "wall"),
        "age": max(0, now - num(str(lad.get("at")), 0)),
    }
except Exception:
    pass

print(json.dumps(out, separators=(",", ":")))
PY
