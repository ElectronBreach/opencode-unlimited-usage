#!/bin/bash
# zen identity — the one place that decides what "a new identity" means.
#
# opencode's free quota is keyed on the address their server sees when the
# request arrives. with warp that is cloudflare's *egress* block, not the
# utun address on this machine, and the bucket is the whole IPv6 /64: the
# interface id inside it is regenerated per connection and does not move the
# quota.
#
# The rule both the guard and the manual hop obey:
#
#     a rotation is real when the egress /64 changes.
#     a new device id, a new v4 address, or a different edge is not a rotation.
#
# A registration that hands back the same /64 is the same wall. Accepting it
# as success is how a rotation looks fine, the message is re-sent, and the
# user concludes the whole thing is broken.
#
# This file is sourced, never executed. Everything is namespaced oui_*.
set -u

OUI_DEST="${OUI_DEST:-$HOME/.local/share/opencode-unlimited}"
OUI_GUARD="${OUI_GUARD:-$OUI_DEST/guard}"
OUI_STATE="${OUI_STATE:-$OUI_GUARD/state.json}"
OUI_LEDGER="${OUI_LEDGER:-$OUI_GUARD/identities.json}"
OUI_BL_MAX="${OUI_BL_MAX:-200}"

# ---- address normalisation ------------------------------------------------

# oui64 <addr> — the quota key for a v6 address. a v4 address is its own key.
oui64(){
  case "${1:-}" in
    *:*) printf '%s' "$1" | awk -F: '{print $1":"$2":"$3":"$4}' ;;
    *)   printf '%s' "${1:-}" ;;
  esac
}

# oui_is_egress <key> — does this key name a cloudflare *egress* block?
#
# warp's egress v6 is 2a09:bac*::/32. the utun address on this box is
# 2606:4700:110::/48 — the tunnel's inside leg, which no server ever sees,
# and which used to end up on the blacklist because it looks like an address.
oui_is_egress(){
  case "${1:-}" in
    2a09:bac*) return 0 ;;
    104.28.*|162.159.*|172.64.*|188.114.*|104.20.*|172.66.*|104.21.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- live probes ----------------------------------------------------------

oui_probe6(){
  curl -6 -sS -m 6 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}
oui_probe4(){
  curl -4 -sS -m 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
    | awk -F= '/^ip=/{print $2; exit}'
}

# oui_bucket — the bucket the server is currently keying on. v6 /64 first,
# because that is what a dual-stack request actually carries; the v4 falls
# back only when the tunnel has no v6 path at all.
oui_bucket(){
  local a b
  a=$(oui_probe6 2>/dev/null || true)
  if [ -n "$a" ] && oui_is_egress "$(oui64 "$a")"; then
    oui64 "$a"; return 0
  fi
  b=$(oui_probe4 2>/dev/null || true)
  if [ -n "$b" ] && oui_is_egress "$b"; then
    printf '%s' "$b"; return 0
  fi
  return 1
}

# ---- state helpers (atomic, the file is read by the HUD too) ---------------

oui_state_get(){
  python3 - "$OUI_STATE" "$1" <<'PY' 2>/dev/null
import json,sys
p,k=sys.argv[1],sys.argv[2]
try: d=json.load(open(p))
except Exception: d={}
v=d.get(k,"")
if isinstance(v,(list,dict)): print(json.dumps(v))
else: print("" if v is None else v)
PY
}

oui_state_set(){
  python3 - "$OUI_STATE" "$1" "$2" <<'PY' 2>/dev/null
import json,sys,os
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
try: d=json.load(open(p))
except Exception: d={}
d[k]=v
t=p+".tmp"
os.makedirs(os.path.dirname(p),exist_ok=True)
with open(t,"w") as f: json.dump(d,f,separators=(",",":"))
os.replace(t,p)
PY
}

# ---- blacklist ------------------------------------------------------------

# oui_bl_add <bucket> — record a burnt bucket. only egress keys are stored;
# anything else is refused rather than silently occupying a slot forever.
oui_bl_add(){
  local k
  k=$(oui64 "${1:-}")
  [ -n "$k" ] || return 1
  oui_is_egress "$k" || return 1
  python3 - "$OUI_STATE" "$k" "${OUI_BL_MAX:-200}" <<'PY' 2>/dev/null
import json,sys,os
p,k,cap=sys.argv[1],sys.argv[2],int(sys.argv[3])
try: d=json.load(open(p))
except Exception: d={}
bl=[x for x in d.get("blacklist",[]) if x and x!=k]
bl.append(k)
d["blacklist"]=bl[-cap:]
t=p+".tmp"
os.makedirs(os.path.dirname(p),exist_ok=True)
with open(t,"w") as f: json.dump(d,f,separators=(",",":"))
os.replace(t,p)
PY
}

oui_bl_has(){
  local k
  k=$(oui64 "${1:-}")
  [ -n "$k" ] || return 1
  python3 - "$OUI_STATE" "$k" <<'PY' 2>/dev/null
import json,sys
p,k=sys.argv[1],sys.argv[2]
try: d=json.load(open(p))
except Exception: sys.exit(1)
sys.exit(0 if k in (d.get("blacklist") or []) else 1)
PY
}

oui_bl_list(){
  python3 - "$OUI_STATE" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
for x in d.get("blacklist",[]):
    print(x)
PY
}

# oui_bl_migrate — one-time repair of a blacklist written before the rule
# existed. it holds three kinds of junk on this box: the tunnel's inside leg
# (2606:4700:110:*), bare v4 duplicates of the same bucket, and the same
# entry twice. drop all of it, keep only normalised egress keys, newest last.
oui_bl_migrate(){
  python3 - "$OUI_STATE" "${OUI_BL_MAX:-200}" <<'PY' 2>/dev/null
import json,sys,os
p,cap=sys.argv[1],int(sys.argv[2])

def is_egress(k):
    if k.startswith("2a09:bac"): return True
    for pre in ("104.28.","162.159.","172.64.","188.114.","104.20.","172.66.","104.21."):
        if k.startswith(pre): return True
    return False

def norm(a):
    a=(a or "").strip()
    if not a: return ""
    if ":" in a: return ":".join(a.split(":")[:4])
    return a

try: d=json.load(open(p))
except Exception: return_=None; d={}

out, seen = [], set()
for x in d.get("blacklist",[]):
    k=norm(x)
    if not k or k in seen or not is_egress(k): continue
    seen.add(k); out.append(k)
out=out[-cap:]
changed = out != [norm(x) for x in d.get("blacklist",[])]
d["blacklist"]=out
if changed:
    t=p+".tmp"
    with open(t,"w") as f: json.dump(d,f,separators=(",",":"))
    os.replace(t,p)
    print("migrated: %d -> %d entries" % (len(seen), len(out)))
PY
}

# ---- identity ledger ------------------------------------------------------
#
# one record per bucket, so the guard can tell "this block has burned twice"
# from "this block is new", and the HUD can show what the current identity has
# actually spent. events: hop | wall | seen
oui_ledger(){
  python3 - "$OUI_LEDGER" "$1" "$2" "${3:-}" <<'PY' 2>/dev/null
import json,sys,os,time
p,bucket,event,extra=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
if not bucket: sys.exit(0)
try: d=json.load(open(p))
except Exception: d={"buckets":{}}
b=d.setdefault("buckets",{})
now=int(time.time())
e=b.setdefault(bucket,{"first":now,"last":now,"hops":0,"walls":0,"device":""})
e["last"]=now
if event=="hop": e["hops"]=int(e.get("hops") or 0)+1
if event=="wall": e["walls"]=int(e.get("walls") or 0)+1
if extra: e["device"]=extra
# keep it bounded — this is a diagnostic, not an archive
if len(b)>400:
    for k in sorted(b, key=lambda k: b[k].get("last",0))[:len(b)-400]:
        b.pop(k,None)
t=p+".tmp"
os.makedirs(os.path.dirname(p),exist_ok=True)
with open(t,"w") as f: json.dump(d,f,separators=(",",":"))
os.replace(t,p)
PY
}

oui_ledger_for(){
  python3 - "$OUI_LEDGER" "$1" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("{}"); sys.exit(0)
print(json.dumps(d.get("buckets",{}).get(sys.argv[2],{})))
PY
}
