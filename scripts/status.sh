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
       OUC_LEAK="$leak" OUC_STATE="$STATE" OUC_DB="$DB" OUC_CTX_DIR="$ctx_dir" \
       OUC_CTX_TS="$ctx_ts" OUC_BRAND="$BRAND" OUC_DEST="$DEST"

python3 - <<'PY'
import json, os, sqlite3, time

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
}

# ---- tokens (opencode.db, read-only; WAL is active so never copy the file)
tok = {
    "db": False, "sessions": 0, "input": 0, "output": 0, "reasoning": 0,
    "cacheRead": 0, "cacheWrite": 0, "cost": 0.0,
    "today": {"input": 0, "output": 0, "cost": 0.0, "sessions": 0},
    "last": None, "recent": [], "models": [],
}
db = env("OUC_DB")
if os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)
        con.row_factory = sqlite3.Row
        c = con.cursor()
        r = c.execute("""SELECT COUNT(*) n, COALESCE(SUM(tokens_input),0) ti,
                                COALESCE(SUM(tokens_output),0) to_,
                                COALESCE(SUM(tokens_reasoning),0) tr,
                                COALESCE(SUM(tokens_cache_read),0) tcr,
                                COALESCE(SUM(tokens_cache_write),0) tcw,
                                COALESCE(SUM(cost),0) cost FROM session_v2""").fetchone()
        tok.update({
            "db": True, "sessions": r["n"], "input": r["ti"], "output": r["to_"],
            "reasoning": r["tr"], "cacheRead": r["tcr"], "cacheWrite": r["tcw"],
            "cost": round(r["cost"] or 0, 4),
        })
        r = c.execute("""SELECT COUNT(*) n, COALESCE(SUM(tokens_input),0) ti,
                                COALESCE(SUM(tokens_output),0) to_,
                                COALESCE(SUM(cost),0) cost FROM session_v2
                         WHERE date(time_updated/1000,'unixepoch','localtime')
                               = date('now','localtime')""").fetchone()
        tok["today"] = {"sessions": r["n"], "input": r["ti"], "output": r["to_"],
                        "cost": round(r["cost"] or 0, 4)}
        def model_name(m):
            m = m or ""
            try:
                j = json.loads(m)
                n = j.get("id") or j.get("modelID") or m
                return "%s/%s" % (j["providerID"], n) if j.get("providerID") else n
            except Exception:
                return m

        rows = c.execute("""SELECT title, tokens_input, tokens_output,
                                   cost, model, time_updated
                            FROM session_v2 ORDER BY time_updated DESC LIMIT 12""").fetchall()
        for i, row in enumerate(rows):
            d = dict(row)
            item = {
                "title": (d.get("title") or "untitled")[:64],
                "tokens": (d.get("tokens_input") or 0) + (d.get("tokens_output") or 0),
                "input": d.get("tokens_input") or 0,
                "output": d.get("tokens_output") or 0,
                "cost": round(d.get("cost") or 0, 4),
                "model": model_name(d.get("model")),
                "age": max(0, now - int((d.get("time_updated") or 0) / 1000)),
            }
            if i == 0:
                tok["last"] = item
            tok["recent"].append(item)
        rows = c.execute("""SELECT model, COUNT(*) AS n,
                                   SUM(tokens_input+tokens_output) AS tok,
                                   SUM(cost) AS cost
                            FROM session_v2 GROUP BY model
                            ORDER BY tok DESC LIMIT 4""").fetchall()
        for row in rows:
            d = dict(row)
            tok["models"].append({"name": model_name(d.get("model")),
                                  "sessions": d.get("n") or 0,
                                  "tokens": d.get("tok") or 0,
                                  "cost": round(d.get("cost") or 0, 4)})
        con.close()
    except Exception as e:
        tok["error"] = str(e)[:200]
out["tokens"] = tok

print(json.dumps(out, separators=(",", ":")))
PY
