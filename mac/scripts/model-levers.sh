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
DEAD="$DEST/guard/models-dead.json"
ZEN="https://opencode.ai/inference/openai/v1/models"
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
  [ -n "$want" ] || die "usage: model-levers set <id|index|provider/model>"
  # a full provider/model reference is set verbatim: the free pool is not the
  # only place a session can run, and pinning a provider model must not need a
  # hand-edited config.
  case "$want" in
    */*)
      python3 - "$CONF" "$want" <<'PY2'
import json,os,sys
conf,ref=sys.argv[1:3]
try:
    d=json.load(open(conf))
except Exception:
    d={}
prov,_,mid=ref.partition("/")
have=((d.get("provider") or d.get("providers") or {}).get(prov) or {})
if not have:
    print("no such provider in config: %s" % prov, file=sys.stderr); sys.exit(3)
if not mid:
    print("usage: provider/model", file=sys.stderr); sys.exit(3)
d["model"]=ref
tmp=conf+".tmp"
with open(tmp,"w") as f:
    json.dump(d,f,indent=2)
os.replace(tmp,conf)
PY2
      [ $? -eq 0 ] || exit 3
      printf 'model → %s\n' "$want"
      return 0 ;;
  esac
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

# a model that answers 429 (free wall) or 400 ("Model is unavailable") is not a
# rotation target — picking it just moves the error one tap closer to the user.
mark_dead(){
  local mid="$1" code="${2:-429}"
  python3 - "$DEAD" "$mid" "$code" <<'PY' 2>/dev/null
import json,os,sys,time
p,mid,code=sys.argv[1],sys.argv[2],sys.argv[3]
try: d=json.load(open(p))
except Exception: d={}
d[mid]={"ts":int(time.time()),"code":code}
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump(d,open(p,"w"),separators=(",",":"))
PY
}

cmd_next(){
  ensure_catalog
  local pick
  pick=$(python3 - "$CATALOG" "$PROVIDER" "$USED" "$DEAD" <<'PY'
import json,sys,time
cat,prov,usedf,deadf=sys.argv[1:5]
d=json.load(open(cat))
try: used=set(json.load(open(usedf)))
except Exception: used=set()
try: dead=json.load(open(deadf))
except Exception: dead={}
now=time.time()
def cooled(mid):
    e=dead.get(mid) or {}
    ttl=1800 if str(e.get("code"))=="429" else 21600
    return (now-float(e.get("ts") or 0)) > ttl
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type")=="chat":
        rows.append(mid)
for mid in rows:
    if mid in used: continue
    if not cooled(mid): continue
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

# ask the console, one token, which free models are actually being served right
# now. `next` already skips what this writes down, so a single probe turns the
# model lever from "hope" into "pick one that answers".
# failover, not hope: walk the free pool, ask each model one token, and pin the
# first one that actually answers. the guard calls this after an account-side
# wall, where rotating the /64 has already been proven pointless.
cmd_fallback(){
  local max="${1:-8}" i=0 mid key
  ensure_catalog
  key=$(sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "select value from credential where integration_id='opencode' and active=1 limit 1;" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')
  [ -n "$key" ] || { printf 'no active opencode credential\n' >&2; exit 4; }
  for mid in $(python3 - "$CATALOG" "$PROVIDER" "$USED" "$DEAD" <<'PY2'
import json,sys,time
cat,prov,usedf,deadf=sys.argv[1:5]
d=json.load(open(cat))
try: used=set(json.load(open(usedf)))
except Exception: used=set()
try: dead=json.load(open(deadf))
except Exception: dead={}
now=time.time()
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type")=="chat" and mid not in used:
        e=dead.get(mid) or {}
        ttl=1800 if str(e.get("code"))=="429" else 21600
        if (now-float(e.get("ts") or 0)) < ttl: continue
        print(mid)
PY2
); do
    [ "$i" -lt "$max" ] || break
    i=$((i+1))
    local code
    code=$(curl -s -o /dev/null -m 15 \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
      -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
      -w '%{http_code}' "${ZEN%/models}/chat/completions" 2>/dev/null)
    case "$code" in
      2*) cmd_set "$mid" >/dev/null && { printf '%s/%s\n' "$PROVIDER" "$mid"; exit 0; } ;;
      429) mark_dead "$mid" 429 >/dev/null 2>&1 ;;
      400) mark_dead "$mid" 400 >/dev/null 2>&1 ;;
    esac
  done
  printf 'no free model answered (tried %d)\n' "$i" >&2
  exit 1
}

cmd_probe(){
  local n="${1:-4}" i=0 mid
  ensure_catalog
  local key
  key=$(sqlite3 "$HOME/.local/share/opencode/opencode.db" \
    "select value from credential where integration_id='opencode' and active=1 limit 1;" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')
  [ -n "$key" ] || { printf 'no active opencode credential\n'; exit 4; }
  for mid in $(python3 - "$CATALOG" "$PROVIDER" "$USED" "$DEAD" <<'PY'
import json,sys,time
cat,prov,usedf,deadf=sys.argv[1:5]
d=json.load(open(cat))
try: used=set(json.load(open(usedf)))
except Exception: used=set()
try: dead=json.load(open(deadf))
except Exception: dead={}
now=time.time()
out=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type")=="chat" and mid not in used:
        out.append(mid)
print("\n".join(out))
PY
); do
    [ "$i" -lt "$n" ] || break
    i=$((i+1))
    local code
    code=$(curl -s -o /dev/null -m 15 \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
      -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
      -w '%{http_code}' "${ZEN%/models}/chat/completions" 2>/dev/null)
    case "$code" in
      2*)      printf 'ok    %s\n' "$mid" ;;
      429)     mark_dead "$mid" 429; printf 'wall  %s (429)\n' "$mid" ;;
      400)     mark_dead "$mid" 400; printf 'gone  %s (model unavailable)\n' "$mid" ;;
      *)       printf '?     %s (%s)\n' "$mid" "$code" ;;
    esac
  done
}

# what the config already carries keys for: every provider block and its models.
# the sheet's PROV page is this list, and a tap pins one.
cmd_providers(){
  local fmt="${1:-}"
  python3 - "$CONF" <<'PY'
import json,os,sys
conf=sys.argv[1]
try: d=json.load(open(conf))
except Exception: d={}
out=[]
for pid,p in (d.get("provider") or d.get("providers") or {}).items():
    ms=[]
    for mid,m in (p.get("models") or {}).items():
        ms.append({"id":mid,
                   "ctx":((m.get("limit") or {}).get("context") or 0)})
    out.append({"id":pid,"label":(p.get("name") or pid),"models":ms})
print(json.dumps({"current":d.get("model") or "","providers":out},separators=(",",":")))
PY
}

cmd_json(){
  ensure_catalog
  python3 - "$CATALOG" "$PROVIDER" "$USED" "$(current_id)" "$DEAD" <<'PY'
import json,sys,time
cat,prov,usedf,cur=sys.argv[1:5]
d=json.load(open(cat))
try: used=json.load(open(usedf))
except Exception: used=[]
try: dead=json.load(open(sys.argv[5]))
except Exception: dead={}
now=time.time()
def deadcode(mid):
    e=dead.get(mid) or {}
    if not e: return None
    ttl=1800 if str(e.get("code"))=="429" else 21600
    return None if (now-float(e.get("ts") or 0)) > ttl else str(e.get("code"))
rows=[]
for mid,m in ((d.get(prov) or {}).get("models") or {}).items():
    c=((m.get("cost") or {}).get("text") or {})
    if (c.get("input") or {}).get("price")==0 and (c.get("output") or {}).get("price")==0 \
       and m.get("type") in ("chat","decision"):
        rows.append({"id":mid,"name":m.get("name") or mid,
                     "ctx":(m.get("limit") or {}).get("context") or 0,
                     "burned": mid in used, "current": mid==cur,
                     "dead": deadcode(mid)})
print(json.dumps({"provider":prov,"current":cur,"dead":len([r for r in rows if r["dead"]]),"free":len(rows),
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
  dead)      shift; mark_dead "${1:-}" "${2:-429}"; printf 'marked %s dead (%s)\n' "${1:-}" "${2:-429}" ;;
  probe)     shift; cmd_probe "${1:-4}" ;;
  fallback|failover) shift; cmd_fallback "${1:-8}" ;;
  reset)     cmd_reset ;;
  refresh)   refresh; printf 'catalog refreshed\n' ;;
  json)      cmd_json ;;
  providers|prov) shift; cmd_providers "${1:-}" ;;
  *)         cat >&2 <<EOF
usage: model-levers list | current | set <id|index> | next | burn <id> | reset | json
EOF
             exit 2 ;;
esac
