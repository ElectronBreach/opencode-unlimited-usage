#!/bin/bash
# wall-log — append one line to guard/walls.jsonl from anywhere.
#
# the guard records walls and landings. the other levers (model switch, key
# rotation, proxy rotation) record themselves here, so the report can answer
# "which lever actually bought time" instead of "which lever did you press".
set -u

DEST="$HOME/.local/share/opencode-unlimited"
G="$DEST/guard"
mkdir -p "$G" 2>/dev/null || true

what="${1:-event}"
extra="${2:-}"

python3 - "$G/walls.jsonl" "$what" "$extra" <<'PY' 2>/dev/null
import json,os,sys,time
path,what,extra=sys.argv[1],sys.argv[2],sys.argv[3]
h=os.path.expanduser("~")
def jload(p, d=None):
    try: return json.load(open(p))
    except Exception: return d if d is not None else {}
conf=jload(os.path.join(h,".config/opencode/opencode.json"))
model=conf.get("model") or ""
rec={
 "ts":int(time.time()),
 "what":what,
 "extra":extra,
 "model":model.split("/")[-1] if model else "",
 "provider":model.split("/")[0] if "/" in model else "",
}
st=jload(os.path.join(h,".local/share/opencode-unlimited/guard/state.json"))
px=jload(os.path.join(h,".local/share/opencode-unlimited/guard/proxy-state.json"))
rec["bucket"]=st.get("current_block") or st.get("bucket") or ""
rec["ip"]=st.get("current") or ""
rec["proxy_up"]=bool(px.get("up"))
rec["proxy_current"]=px.get("current") or ""
rec["proxy_pool"]=px.get("pool") or 0
try:
    with open(path,"a") as f: f.write(json.dumps(rec,separators=(",",":"))+"\n")
except Exception:
    pass
PY
