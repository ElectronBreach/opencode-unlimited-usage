#!/bin/bash
# model-levers — the cheapest bypass lever there is.
#
# The client's own wall message is the spec:
#
#   "Free usage limit reached. Connect a provider or subscribe to OpenCode Go
#    to keep going, or switch models."
#
# So the free tier is not one bucket, it is one bucket per model. This machine
# has 51 zero-cost chat models on the `opencode` provider, which is 51 free
# buckets against the eight /64s WARP will hand out — and switching one costs
# no tunnel, no registration, no DNS window, no key probe.
#
#   model-levers list                 free models, current one marked
#   model-levers current              what the CLI will run
#   model-levers set <id|index>       pin a model (writes ~/.config/opencode/opencode.json)
#   model-levers next                 move to the next model this run has not burned
#   model-levers burn <id>            record a model as walled
#   model-levers reset                forget the burned list
#   model-levers json                 {"current":…,"free":[…]}
#
# The catalog is cached for a day; `refresh` forces a re-fetch.
set -u

BRAND=opencode-unlimited
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
CATALOG="$DEST/models.json"
USED="$GUARD_DIR/models-used.json"
CONF="$HOME/.config/opencode/opencode.json"
URL="https://models.opencode.ai/experimental/v2.0/api.json"
PROVIDER="${OUC_MODEL_PROVIDER:-opencode}"
TTL="${OUC_MODEL_TTL:-86400}"

mkdir -p "$GUARD_DIR" "$DEST"

die(){ printf '%s\n' "$*" >&2; exit "${2:-1}"; }

refresh(){
  local tmp="$CATALOG.tmp"
  if curl -fsS --max-time 20 "$URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] \
     && python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv "$tmp" "$CATALOG"
  else
    rm -f "$tmp"
    [ -s "$CATALOG" ] || die "no catalog and the fetch failed — offline and uncached"
  fi
}

ensure_catalog(){
  if [ ! -s "$CATALOG" ]; then refresh; return; fi
  local age
  age=$(( $(date +%s) - $(stat -f %m "$CATALOG" 2>/dev/null || echo 0) ))
  [ "$age" -gt "$TTL" ] && refresh
  return 0
}

# one line per free chat model, `id<TAB>name<TAB>context`
free_rows(){
  python3 - "$CATALOG" "$PROVIDER" <<'PY'
import json,sys
cat,prov=sys.argv[1],sys.argv[2]
try: d=json.load(open(cat))
except Exception: raise SystemExit(1)
p=d.get(prov) or {}
for mid,m in (p.get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    ip=(c.get("input") or {}).get("price")
    op=(c.get("output") or {}).get("price")
    if ip==0 and op==0 and m.get("type") in ("chat","decision"):
        print("%s\t%s\t%s" % (mid, m.get("name") or mid,
                              (m.get("limit") or {}).get("context") or 0))
PY
}

# the CLI accepts "provider/model" or an object; this prints the bare model id
current_id(){
  python3 - "$CONF" "$PROVIDER" <<'PY'
import json,os,sys
conf,prov=sys.argv[1],sys.argv[2]
try: d=json.load(open(conf))
except Exception: print(""); raise SystemExit
m=d.get("model")
if isinstance(m,dict):
    print(m.get("model") or "")
elif isinstance(m,str):
    print(m.split("/",1)[1] if "/" in m else m)
else:
    print("")
PY
}

cmd_set(){
  local want="${1:-}"
  [ -n "$want" ] || die "usage: model-levers set <id|index>"
  ensure_catalog
  local id
  id=$(python3 - "$want" "$CATALOG" "$PROVIDER" <<'PY'
import json,sys
want,cat,prov=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(cat))
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type") in ("chat","decision"):
        rows.append(mid)
if want.isdigit():
    i=int(want)
    print(rows[i-1] if 1<=i<=len(rows) else "")
else:
    print(want if want in rows else "")
PY
)
  [ -n "$id" ] || die "not a free model: $want  (model-levers list)"
  python3 - "$CONF" "$PROVIDER" "$id" <<'PY'
import json,os,sys
conf,prov,mid=sys.argv[1:4]
try:
    d=json.load(open(conf))
except Exception:
    d={"$schema":"https://opencode.ai/config.json"}
d["model"]="%s/%s" % (prov,mid)
tmp=conf+".tmp"
with open(tmp,"w") as f:
    json.dump(d,f,indent=2)
os.replace(tmp,conf)
PY
  printf 'model → %s/%s\n' "$PROVIDER" "$id"
}

cmd_current(){
  local id; id=$(current_id)
  [ -n "$id" ] && printf '%s/%s\n' "$PROVIDER" "$id" || printf '(config default — the CLI picks)\n'
}

used_list(){
  python3 - "$USED" <<'PY'
import json,sys
try: print("\n".join(json.load(open(sys.argv[1]))))
except Exception: pass
PY
}

mark_used(){
  python3 - "$USED" "$1" <<'PY'
import json,os,sys
p,mid=sys.argv[1],sys.argv[2]
try: d=json.load(open(p))
except Exception: d=[]
if mid not in d: d.append(mid)
d=d[-200:]
json.dump(d,open(p,"w"),separators=(",",":"))
PY
}

cmd_burn(){
  [ -n "${1:-}" ] || die "usage: model-levers burn <id>"
  mark_used "$1"; printf 'burned %s\n' "$1"
}

# the HUD's BURN button does not know the id, and it should not have to: the
# thing worth burning is always whatever is pinned right now.
cmd_burn_current(){
  local id; id=$(current_id)
  [ -n "$id" ] || die "no default model pinned — nothing to burn"
  mark_used "$id"; printf 'burned %s\n' "$id"
}

cmd_reset(){ rm -f "$USED"; printf 'model burn list cleared\n'; }

cmd_next(){
  ensure_catalog
  local pick
  pick=$(python3 - "$CATALOG" "$PROVIDER" "$USED" <<'PY'
import json,sys
cat,prov,usedf=sys.argv[1:4]
d=json.load(open(cat))
try: used=set(json.load(open(usedf)))
except Exception: used=set()
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type")=="chat":
        rows.append(mid)
for mid in rows:
    if mid not in used:
        print(mid); raise SystemExit
raise SystemExit(3)
PY
)
  [ -n "$pick" ] || { printf 'every free model is burned for this run\n'; exit 3; }
  cmd_set "$pick" >/dev/null || exit 4
  mark_used "$pick"
  printf '%s/%s\n' "$PROVIDER" "$pick"
}

cmd_list(){
  ensure_catalog
  local cur; cur=$(current_id)
  python3 - "$CATALOG" "$PROVIDER" "$USED" "$cur" <<'PY'
import json,sys
cat,prov,usedf,cur=sys.argv[1:5]
d=json.load(open(cat))
try: used=set(json.load(open(usedf)))
except Exception: used=set()
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type") in ("chat","decision"):
        rows.append((mid, m.get("name") or mid,
                     (m.get("limit") or {}).get("context") or 0,
                     m.get("type")))
print("%-3s %-3s %-46s %9s" % ("", "#", "MODEL", "CONTEXT"))
for i,(mid,name,ctx,typ) in enumerate(rows,1):
    mark="*" if mid==cur else ("x" if mid in used else " ")
    print("%-3s %-3d %-46.46s %9s" % (mark, i, mid, ("%dk" % (ctx//1000)) if ctx else "-"))
print("")
print("%d free · %d burned · %s" % (len(rows), len([r for r in rows if r[0] in used]),
                                    ("current " + cur) if cur else "no default pinned"))
PY
}

cmd_json(){
  ensure_catalog
  python3 - "$CATALOG" "$PROVIDER" "$USED" "$(current_id)" <<'PY'
import json,sys
cat,prov,usedf,cur=sys.argv[1:5]
d=json.load(open(cat))
try: used=json.load(open(usedf))
except Exception: used=[]
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type") in ("chat","decision"):
        rows.append({"id":mid,"name":m.get("name") or mid,
                     "ctx":(m.get("limit") or {}).get("context") or 0,
                     "burned": mid in used, "current": mid==cur})
print(json.dumps({"provider":prov,"current":cur,"free":len(rows),
                  "burned":len([r for r in rows if r["burned"]]),
                  "models":rows},separators=(",",":")))
PY
}

case "${1:-list}" in
  list|ls)   cmd_list ;;
  current)   cmd_current ;;
  set)       shift; cmd_set "${1:-}" ;;
  next)      cmd_next ;;
  burn)      shift; cmd_burn "${1:-}" ;;
  burn-current|burncur) cmd_burn_current ;;
  reset)     cmd_reset ;;
  refresh)   refresh; printf 'catalog refreshed\n' ;;
  json)      cmd_json ;;
  *)         cat >&2 <<EOF
usage: model-levers list | current | set <id|index> | next | burn <id> | reset | json
EOF
             exit 2 ;;
esac
