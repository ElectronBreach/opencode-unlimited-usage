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
det=sorted([e for e in ev if e.get("what")=="detected"], key=lambda e:e["ts"])
land=sorted([e for e in ev if e.get("what")=="landed"], key=lambda e:e["ts"])

print("walls: %d   landings: %d" % (len(det), len(land)))
if len(det)>1:
    span=(det[-1]["ts"]-det[0]["ts"])/3600
    if span>0: print("window: %.1fh   rate: %.1f walls/h" % (span, len(det)/span))

def summary(title, items, key, n=5):
    c=Counter(e.get(key) or "-" for e in items)
    if not c or (len(c)==1 and c.most_common(1)[0][0]=="-"): return
    print("\nby %s:" % title)
    for k,v in c.most_common(n): print("  %-34s %d" % (k[:34], v))

summary("model", det, "model")
summary("provider", det, "provider")
summary("bucket", det, "bucket")
summary("proxy", det, "proxy_current")

# lever effectiveness: after each lever event, did a wall arrive inside 10 min?
print("\nlevers:")
rows=[]
for lever in ("model","key","proxy"):
    acts=[e for e in ev if e.get("what")==lever]
    if not acts: continue
    good=0; gaps=[]
    for a in acts:
        nxt=[d for d in det if d["ts"]>a["ts"]]
        if not nxt:
            good+=1; continue
        gap=nxt[0]["ts"]-a["ts"]
        gaps.append(gap)
        if gap>600: good+=1
    med=sorted(gaps)[len(gaps)//2] if gaps else None
    rows.append((lever,len(acts),good,med))
for lever,n,good,med in rows:
    meds = "%dm" % (med//60) if med is not None else "—"
    print("  %-6s %2d applied · %2d held >10min · median next wall %s" % (lever,n,good,meds))
if not rows:
    print("  none recorded yet — model/key/proxy events land here as they happen")

if land:
    bad=sum(1 for l in land if any(0 <= d["ts"]-l["ts"] <= 600 for d in det))
    print("\nlandings followed by a wall within 10 min: %d/%d" % (bad, len(land)))
    if len(land)>=3 and bad*2>=len(land):
        print("  verdict: rotations are not clearing this wall — model/provider levers first")

if det:
    hours=Counter(time.strftime("%m-%d %H:00", time.localtime(e["ts"])) for e in det)
    print("\nlast hours:")
    for h,c in sorted(hours.items())[-12:]:
        print("  %s  %s" % (h, "#"*min(c,40)))
PY
