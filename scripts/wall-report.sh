#!/bin/bash
# wall-report — what the wall actually responds to.
#
# every wall is recorded by zen-guard with model, provider, egress bucket and
# proxy upstream. this reads that file and answers the only question that
# matters when the limit comes back: which lever moved it, and which one was
# theatre.
set -u

DEST="$HOME/.local/share/opencode-unlimited"
G="$DEST/guard/walls.jsonl"

say(){ printf '%s\n' "$*"; }

if [ "${1:-}" = "test" ]; then
  printf '%s\n' '{"ts":0,"what":"detected","extra":"synthetic","model":"test","provider":"opencode","bucket":"test","ip":"","proxy_up":false,"proxy_current":"","proxy_pool":0,"rotations":0}' >> "$G"
  say "synthetic event appended (delete with: sed -i '' '/synthetic/d' $G)"
  exit 0
fi

[ -s "$G" ] || { say "no walls recorded yet — $G is empty"; exit 0; }

python3 - "$G" <<'PY'
import json,sys,time
from collections import Counter
path=sys.argv[1]
raw=[l for l in open(path) if l.strip()]
ev=[]
for l in raw:
    try: ev.append(json.loads(l))
    except Exception: pass
if not ev:
    print("no parsable events"); raise SystemExit
now=time.time()
det=[e for e in ev if e.get("what")=="detected"]
land=[e for e in ev if e.get("what")=="landed"]

print("walls: %d   landings: %d" % (len(det), len(land)))
if det:
    span=(det[-1]["ts"]-det[0]["ts"])/3600 if len(det)>1 else 0
    if span>0: print("window: %.1fh   rate: %.1f walls/h" % (span, len(det)/span))

def top(key, n=5):
    c=Counter(e.get(key) or "-" for e in det)
    return c.most_common(n)

for label,key in (("model","model"),("provider","provider"),("bucket","bucket"),("proxy","proxy_current")):
    c=top(key)
    if not c or (len(c)==1 and c[0][0]=="-"): continue
    print("\nby %s:" % label)
    for k,v in c: print("  %-34s %d" % (k[:34], v))

# did a wall come back soon after a landing? that lever bought nothing.
if land:
    failed=0
    for l in land:
        if any(0 <= d["ts"]-l["ts"] <= 600 for d in det):
            failed+=1
    print("\nlandings followed by a wall within 10 min: %d/%d" % (failed, len(land)))
    if len(land) >= 3 and failed*2 >= len(land):
        print("  verdict: rotations are not clearing this wall — try model or provider levers first")

# per hour, last 12 buckets
if det:
    hours=Counter(time.strftime("%m-%d %H:00", time.localtime(e["ts"])) for e in det)
    print("\nlast hours:")
    for h,c in sorted(hours.items())[-12:]:
        print("  %s  %s" % (h, "#"*min(c,40)))
PY
