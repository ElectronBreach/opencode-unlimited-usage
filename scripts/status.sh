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

# ---- cached network probes ------------------------------------------------
c_ts=0; c_ip=""; c_dns=0
if [ -f "$CACHE" ]; then
  eval "$(python3 - "$CACHE" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print("c_ts=%d" % int(d.get("ts") or 0))
print("c_ip=%s" % ("'" + str(d.get("egress4") or "").replace("'","") + "'"))
print("c_dns=%d" % (1 if d.get("dns") else 0))
PY
)"
fi
net_age=$(( now - c_ts ))
if [ "$FORCE" = "1" ] || [ "$net_age" -gt "$TTL" ] || [ -z "$c_ip" ]; then
  c_ip=$(curl -4 -s -m 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
  [ -n "$c_ip" ] || c_ip=$(curl -4 -s -m 3 https://api64.ipify.org 2>/dev/null)
  if [ -n "$(dig +short +time=1 +tries=1 opencode.ai 2>/dev/null)" ]; then c_dns=1; else c_dns=0; fi
  c_ts=$now
  printf '{"ts":%d,"egress4":"%s","dns":%d}\n' "$c_ts" "${c_ip:-}" "$c_dns" > "$CACHE.tmp" 2>/dev/null \
    && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
fi

# ---- local state ----------------------------------------------------------
tunnel=0; mode=""
if [ -n "$WARP" ]; then
  wo status 2>/dev/null | head -1 | grep -q Connected && tunnel=1
  mode=$(wo settings 2>/dev/null | awk -F'Mode: ' '/Mode:/{print $2; exit}')
fi
keeper=0; launchctl print system/com.opencode-unlimited.keeper >/dev/null 2>&1 && keeper=1
guard=0;  launchctl print "gui/$(id -u)/com.opencode-unlimited.guard" >/dev/null 2>&1 && guard=1
credit=0; [ -f "$HOME/.opencode/AGENTS.md" ] && credit=1
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

export OUC_NOW="$now" OUC_IP="${c_ip:-}" OUC_DNS="$c_dns" OUC_TUNNEL="$tunnel" \
       OUC_MODE="$mode" OUC_KEEPER="$keeper" OUC_GUARD="$guard" OUC_CREDIT="$credit" \
       OUC_LEAK="$leak" OUC_STATE="$STATE" OUC_LEDGER="$GUARD/identities.json" OUC_DB="$DB" OUC_CTX_DIR="$ctx_dir" \
       OUC_CTX_TS="$ctx_ts" OUC_BRAND="$BRAND" OUC_DEST="$DEST"

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
    "dns": env("OUC_DNS") == "1",
    "credit": env("OUC_CREDIT") == "1",
    "leakguard": env("OUC_LEAK"),
    "egress4": env("OUC_IP"),
    "context": {"dir": env("OUC_CTX_DIR"), "age": (now - num(env("OUC_CTX_TS"))) if env("OUC_CTX_TS") else -1},
}

# ---- guard state
st = {}
try:
    with open(env("OUC_STATE")) as f:
        st = json.load(f)
except Exception:
    pass
out["identity"] = {
    "current": st.get("current") or "",
    "prefix": st.get("prefix") or "",
    "seen6": st.get("seen6") or "",
    "device": (st.get("device") or "")[:8],
    "hops": num(st.get("hops")),
    "blacklist": len([x for x in (st.get("blacklist") or []) if x]),
    # the bucket is the quota key. burnt is the honest answer to "have we
    # already been walled on this one", which is what the HUD has to show.
    "bucket": st.get("prefix") or "",
    "burnt": bool(st.get("prefix") and st.get("prefix") in (st.get("blacklist") or [])),
    "bucketWalls": 0, "bucketHops": 0,
}
try:
    with open(env("OUC_LEDGER")) as f:
        led = json.load(f).get("buckets", {})
    e = led.get(st.get("prefix") or "", {}) or {}
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

print(json.dumps(out, separators=(",", ":")))
PY
