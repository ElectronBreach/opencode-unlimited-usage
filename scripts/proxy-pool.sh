#!/bin/bash
# proxy-pool — the custom-egress rotation layer.
#
# WARP hands out a handful of /64s and each one costs a registration and a
# moment where DNS is in flux. A proxy pool is the other lever: somebody else's
# IP, switched locally, no tunnel touched. webshare exports `host:port:user:pass`
# and this eats that directly.
#
#   proxy-pool add host:port:user:pass      (or user:pass@host:port, or a URL)
#   proxy-pool list | test [n] | remove <n>
#   proxy-pool on                           start the local mux (no system change)
#   proxy-pool sys on|off                   point the whole machine at the mux
#   proxy-pool off                          stop it, restore the system proxy
#   proxy-pool rotate [next|slot n]         switch upstream, no restart
#   proxy-pool status | json
#
# The client only ever talks to 127.0.0.1:8899. Rotation happens behind it, so
# nothing has to be restarted and no tunnel has to be torn down.
set -u

BRAND=opencode-unlimited
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
POOL="$DEST/proxies.txt"
STATE="$GUARD_DIR/proxy-state.json"
HEALTH="$GUARD_DIR/proxy-health.json"
CMD="$GUARD_DIR/proxy-cmd"
SYSBASE="$GUARD_DIR/proxy-system.json"
CONF="$DEST/proxy.conf"
LOG="$GUARD_DIR/proxy-mux.log"
MUX="$DEST/scripts/proxy-mux.py"
PORT="${OUC_PROXY_PORT:-8899}"
CAP="${OUC_PROXY_CAP:-200}"

mkdir -p "$GUARD_DIR"; touch "$POOL"

say(){ printf '%s\n' "$*"; }
err(){ printf '%s\n' "$*" >&2; }

norm(){  # normalize one spec to scheme://user:pass@host:port (or keep direct)
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
if s == "direct":
    print("direct"); raise SystemExit
scheme = "http"
if "://" in s:
    scheme, s = s.split("://", 1)
    scheme = scheme.lower()
if scheme not in ("http", "https", "socks4", "socks5", "socks5h"):
    print(""); raise SystemExit
if "@" in s:
    cred, hostport = s.rsplit("@", 1)
    user, _, pw = cred.partition(":")
elif s.count(":") == 3:
    host, port, user, pw = s.split(":", 3)
    hostport = host + ":" + port
else:
    user = pw = ""
    hostport = s
host, _, port = hostport.rpartition(":")
if not host or not port.isdigit() or not (0 < int(port) < 65536):
    print(""); raise SystemExit
if not user:
    print("%s://%s:%s" % (scheme, host, port))
else:
    print("%s://%s:%s@%s:%s" % (scheme, user, pw, host, port))
PY
}

key_of(){ printf '%s' "${1#*://}" | sed 's/^[^@]*@//'; }

# grep -c always prints a number, even when it finds nothing — the old
# `|| echo 0` therefore produced "0\n0" and every arithmetic test blew up.
# the mux's own claim plus a live pid — a stale "up":true after a kill must
# never read as running, here or in the HUD.
state_up(){
  python3 -c 'import json,os,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(0); raise SystemExit
pid=d.get("pid") or 0
ok=d.get("up") and pid
if ok:
    try: os.kill(int(pid),0)
    except Exception: ok=False
print(1 if ok else 0)' "$STATE" 2>/dev/null
}

count(){
  local n
  n=$(grep -cv '^\s*\(#\|$\)' "$POOL" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# the pool emptied itself twice with no explanation. a mutation log that names
# the caller is cheaper than guessing: every write records argv, ppid and count.
pool_log(){
  local msg="$1"
  printf '%s n=%s ppid=%s argv=%s\n' \
    "$(date +%H:%M:%S)" "$(count)" "${PPID:-?}" "$(ps -o args= -p "${PPID:-0}" 2>/dev/null | cut -c1-80)" \
    >> "$GUARD_DIR/proxy-mutations.log" 2>/dev/null || true
}

pool_backup(){
  [ -s "$POOL" ] && cp "$POOL" "$POOL.last" 2>/dev/null || true
}

cmd_add(){
  local raw="${1:-}" n spec
  [ -n "$raw" ] || { err "usage: proxy-pool add host:port:user:pass"; exit 2; }
  spec=$(norm "$raw")
  [ -n "$spec" ] || { err "not a usable proxy spec: $raw"; exit 2; }
  n=$(count)
  if [ "$spec" != "direct" ] && [ "$n" -ge "$CAP" ]; then
    err "pool is full ($n/$CAP) — remove one first: proxy-pool remove <n>"; exit 3
  fi
  # dedupe on host:port, not on the whole line: the same exit with a rotated
  # password is still the same exit, and two copies just split the rotation.
  if [ "$spec" != "direct" ] && grep -qxF "$spec" "$POOL" 2>/dev/null; then
    say "already in the pool: $spec"; return 0
  fi
  if [ "$spec" != "direct" ]; then
    local k; k=$(key_of "$spec")
    if grep -v '^\s*#' "$POOL" 2>/dev/null | sed 's/^[a-z0-9]*:\/\///; s/^[^@]*@//' | grep -qxF "$k"; then
      say "already in the pool: $k"; return 0
    fi
  fi
  pool_backup
  printf '%s\n' "$spec" >> "$POOL"
  pool_log "add $(printf '%s' "$spec" | sed 's#://.*@#://***@#')"
  say "added $(printf '%s' "$spec" | sed 's#://.*@#://***@#') — $(( $(count) ))/$CAP"
}

# a webshare export is one proxy per line, often with a header row and often
# with commas. rotation only changes the egress when there is more than one
# upstream, so bulk import is the difference between "rotating" and "one ip".
cmd_import(){
  local src="${1:-}" tmp added=0 skipped=0 line spec out
  [ -n "$src" ] || { err "usage: proxy-pool import <file|url>"; exit 2; }
  tmp=$(mktemp)
  case "$src" in
    http://*|https://*) curl -fsSL --max-time 30 "$src" -o "$tmp" || { err "could not fetch $src"; rm -f "$tmp"; exit 3; } ;;
    *) [ -f "$src" ] || { err "no such file: $src"; exit 3; }; cp "$src" "$tmp" ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in ''|'#'*|';'*) continue ;; esac
    # csv header
    case "$line" in *[Pp][Rr][Oo][Xx][Yy]*|*[Ii][Pp]*,*) case "$line" in *,*) continue ;; esac ;; esac
    line=$(printf '%s' "$line" | tr ',' ':')
    spec=$(norm "$line")
    [ -n "$spec" ] || { skipped=$((skipped + 1)); continue; }
    out=$(bash "$0" add "$spec" 2>&1)
    case "$out" in
      *already\ in\ the\ pool*) skipped=$((skipped + 1)) ;;
      *) added=$((added + 1)) ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  say "imported $added · skipped $skipped · pool $(count)/$CAP"
  [ "$(count)" -ge 2 ] || say "note: one upstream means rotation cannot change your egress ip — add more lines"
}

cmd_list(){
  local i=0
  printf '%-4s %-52s %s\n' "#" "UPSTREAM" "LAST"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    i=$((i+1))
    local shown; shown=$(printf '%s' "$line" | sed 's#://\([^@]*\)@#://***@#')
    local last="-"
    if [ -f "$HEALTH" ]; then
      last=$(python3 - "$line" "$HEALTH" <<'PY' 2>/dev/null
import json,sys,time
spec,hp=sys.argv[1],sys.argv[2]
try: d=json.load(open(hp))
except Exception: raise SystemExit(print("-"))
k=spec.split("://",1)[-1].split("@")[-1]
e=d.get(k)
if not e: raise SystemExit(print("-"))
age=int(time.time()-(e.get("ts") or 0))
st=e.get("state") or "?"
print("%s · %ss ago%s" % (st, age, (" · "+e["ip"]) if e.get("ip") else ""))
PY
)
    fi
    printf '%-4s %-52.52s %s\n' "$i" "$shown" "$last"
  done < "$POOL"
  say ""
  say "$(count)/$CAP upstreams"
}

cmd_remove(){
  local n="${1:-}" force="${2:-}"
  case "$n" in ''|*[!0-9]*) err "usage: proxy-pool remove <n> [--force]"; exit 2 ;; esac
  local total; total=$(count)
  [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || { err "no slot $n (pool has $total)"; exit 4; }
  if [ "$total" -le 1 ] && [ "$force" != "--force" ]; then
    err "that is the last upstream — removing it leaves the mux with nothing to rotate (use --force if you mean it)"
    exit 6
  fi
  pool_backup
  python3 - "$POOL" "$n" <<'PY'
import sys
p,n=sys.argv[1],int(sys.argv[2])
lines=open(p).read().splitlines()
out=[];i=0
for l in lines:
    if l.strip() and not l.lstrip().startswith("#"):
        i+=1
        if i==n: continue
    out.append(l)
open(p,"w").write("\n".join(out).rstrip("\n")+"\n")
PY
  pool_log "remove slot $n"
  say "removed slot $n — $(count) left"
  [ -S /dev/null ] 2>/dev/null || true
  printf 'reload\n' > "$CMD" 2>/dev/null || true
}

probe_one(){
  # the target used to be the bare string "cdn-cgi/trace", which is not a host
  # and never resolved — every upstream probed dead, including good ones. an ip
  # literal cannot fail on DNS, and two plain-ip services cover the proxies
  # that refuse CONNECT to 1.1.1.1.
  local spec="$1" url="https://1.1.1.1/cdn-cgi/trace"
  local px="$spec"
  case "$spec" in
    socks5://*) px="socks5h://${spec#socks5://}" ;;
    socks5h://*) px="$spec" ;;
    socks4://*) px="socks4a://${spec#socks4://}" ;;
    https://*) px="$spec" ;;
    http://*) px="$spec" ;;
  esac
  local out ms u
  ms=$(python3 -c 'import time;print(int(time.time()*1000))')
  out=$(curl -s --connect-timeout 8 --max-time 14 -x "$px" "$url" 2>/dev/null)
  case "$out" in *ip=*) ;; *)
    for u in https://api.ipify.org https://ipv4.webshare.io/; do
      out=$(curl -s --connect-timeout 8 --max-time 14 -x "$px" "$u" 2>/dev/null)
      case "$out" in *[0-9].[0-9].[0-9].[0-9]*) break ;; esac
      out=""
    done ;;
  esac
  local ok=1
  case "$out" in *ip=*|*[0-9].[0-9].[0-9].[0-9]*) ok=0 ;; esac
  ms=$(( $(python3 -c 'import time;print(int(time.time()*1000))') - ms ))
  python3 - "$spec" "$ok" "$ms" "$out" <<'PY'
import json,sys,re
spec,ok,ms,out=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
ip=""; colo=""
for line in out.splitlines():
    if line.startswith("ip="): ip=line[3:].strip()
    elif line.startswith("colo="): colo=line[5:].strip()
if not ip:
    m=re.search(r"(\d{1,3}(?:\.\d{1,3}){3})", out)
    if m: ip=m.group(1)
bucket=""
if ":" in ip:
    parts=ip.split(":")
    bucket=":".join(parts[:4])
elif ip:
    bucket=ip
print(json.dumps({"spec":spec,"ok":ok=="0","ms":int(ms),"ip":ip,"colo":colo,"bucket":bucket}))
PY
}

cmd_test(){
  local want="${1:-}" n=0 pass=0 fail=0 rec=""
  local tmp; tmp=$(mktemp)
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n+1))
    [ -n "$want" ] && [ "$want" != "$n" ] && continue
    local r; r=$(probe_one "$line")
    local ok; ok=$(printf '%s' "$r" | python3 -c 'import json,sys;print(1 if json.load(sys.stdin)["ok"] else 0)')
    local ip; ip=$(printf '%s' "$r" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ip",""))')
    local ms; ms=$(printf '%s' "$r" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ms",0))')
    if [ "$ok" = "1" ]; then pass=$((pass+1)); say "  ok    $(printf '%s' "$line" | sed 's#://\([^@]*\)@#://***@#')  ${ip}  ${ms}ms"
    else fail=$((fail+1)); say "  dead  $(printf '%s' "$line" | sed 's#://\([^@]*\)@#://***@#')"; fi
    printf '%s\n' "$r" >> "$tmp"
  done < "$POOL"
  python3 - "$tmp" "$HEALTH" <<'PY'
import json,sys,time
tmp,hp=sys.argv[1],sys.argv[2]
try: d=json.load(open(hp))
except Exception: d={}
now=int(time.time())
for line in open(tmp):
    line=line.strip()
    if not line: continue
    r=json.loads(line)
    k=r["spec"].split("://",1)[-1].split("@")[-1]
    d[k]={"ts":now,"state":"live" if r["ok"] else "dead",
          "ip":r.get("ip",""),"colo":r.get("colo",""),
          "bucket":r.get("bucket",""),"ms":r["ms"]}
d={k:v for k,v in list(d.items())[-400:]}
json.dump(d,open(hp,"w"),separators=(",",":"))
PY
  rm -f "$tmp"
  say ""
  say "$pass live · $fail dead"
  # hand the verdict to the running mux: without this it keeps believing a
  # pool that TEST just proved dead, and its state reads "healthy" anyway.
  if [ "$(state_up)" = "1" ]; then printf 'reload\n' > "$GUARD_DIR/proxy-cmd"; fi
  [ "$fail" -eq 0 ] || return 1
  return 0
}

sys_services(){
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' || true
}

# saving the baseline twice is how "off" restores the proxy instead of the
# machine's own state: the second save photographs 127.0.0.1. first save wins.
systems_save(){
  [ -f "$SYSBASE" ] && return 0
  python3 - "$SYSBASE" <<'PY'
import json,subprocess,sys
out={}
svcs=subprocess.run(["networksetup","-listallnetworkservices"],capture_output=True,text=True).stdout.splitlines()[1:]
for s in svcs:
    s=s.strip()
    if not s or s.startswith("*"): continue
    web=subprocess.run(["networksetup","-getwebproxy",s],capture_output=True,text=True).stdout
    sec=subprocess.run(["networksetup","-getsecurewebproxy",s],capture_output=True,text=True).stdout
    def parse(t):
        d={}
        for line in t.splitlines():
            if ":" in line:
                k,v=line.split(":",1); d[k.strip().lower()]=v.strip()
        return d
    out[s]={"web":parse(web),"sec":parse(sec)}
json.dump(out,open(sys.argv[1],"w"),indent=1)
PY
}

cmd_on(){
  if [ "$(count)" -eq 0 ] && [ -s "$POOL.last" ]; then
    cp "$POOL.last" "$POOL" 2>/dev/null
    say "pool file was empty — restored $(count) upstream(s) from the last good copy"
  fi
  [ "$(count)" -gt 0 ] || { err "pool is empty — proxy-pool add host:port:user:pass"; exit 3; }
  # a marker, not a memory: the guard restarts a mux that dies while this file
  # exists, and `off` is the only thing that removes it.
  : > "$GUARD_DIR/proxy-want"
  pkill -f "proxy-mux.py" 2>/dev/null; sleep 0.4
  OUC_PROXY_PORT="$PORT" OUC_DEST="$DEST" nohup python3 "$MUX" >>"$LOG" 2>&1 &
  local i=0
  while [ "$i" -lt 20 ]; do
    i=$((i+1)); sleep 0.3
    python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('up') else 1)" "$STATE" 2>/dev/null && break
  done
  if ! python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('up') else 1)" "$STATE" 2>/dev/null; then
    err "mux did not come up — see $LOG"; tail -3 "$LOG" >&2; exit 5
  fi
  say "mux up on 127.0.0.1:$PORT · $(count) upstreams · policy $(python3 -c "import json;print(json.load(open('$STATE'))['policy'])" 2>/dev/null)"
  say "for the CLI:  export HTTPS_PROXY=http://127.0.0.1:$PORT"
  say "for every app: proxy-pool sys on   ('off' restores the saved baseline)"
}

# the system-wide switch, deliberately separate from the mux: a listener on
# localhost is harmless, pointing the whole machine at it is not, and each one
# has to be reversible without touching the other.
cmd_sys(){
  local want="${1:-}"
  case "$want" in
  on)
    systems_save
    local n=0 svc
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      networksetup -setwebproxy "$svc" 127.0.0.1 "$PORT" >/dev/null 2>&1
      networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$PORT" >/dev/null 2>&1
      networksetup -setproxybypassdomains "$svc" "*.local" "169.254/16" "127.0.0.1" "localhost" >/dev/null 2>&1
      n=$((n+1))
      say "system proxy → $svc"
    done <<EOF
$(sys_services)
EOF
    mark_sys 1
    say "system proxy ON across $n service(s). 'proxy-pool sys off' restores it."
    ;;
  off)
    if [ -f "$SYSBASE" ]; then
      python3 - "$SYSBASE" <<'PY'
import json,subprocess,sys
d=json.load(open(sys.argv[1]))
for svc,v in d.items():
    for kind,flag in (("web","-setwebproxy"),("sec","-setsecurewebproxy")):
        st=(v.get(kind) or {})
        enabled=str(st.get("enabled","No")).lower()=="yes"
        server=st.get("server") or ""
        port=st.get("port") or "0"
        if enabled and server:
            subprocess.run(["networksetup",flag,svc,server,port],capture_output=True)
            subprocess.run(["networksetup",flag+"state",svc,"on"],capture_output=True)
        else:
            subprocess.run(["networksetup",flag+"state",svc,"off"],capture_output=True)
PY
      rm -f "$SYSBASE"
      say "system proxy restored to the saved baseline"
    else
      say "system proxy was already off — nothing saved to restore"
    fi
    mark_sys 0
    ;;
  *)
    sys_state
    ;;
  esac
}

# the HUD polls status.sh every few seconds and cannot spend a networksetup
# round trip per interface in that path, so the switch records its own verdict
# in the mux state file and status.sh reads that instead.
mark_sys(){
  python3 - "$STATE" "$1" <<'PY'
import json,sys,time
p,v=sys.argv[1],sys.argv[2]
try: d=json.load(open(p))
except Exception: d={"up":False}
d["system"]=(v=="1"); d["sysTs"]=int(time.time())
json.dump(d,open(p,"w"),separators=(",",":"))
PY
}

sys_state(){
  local on=0 svc out
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    out=$(networksetup -getwebproxy "$svc" 2>/dev/null)
    case "$out" in
      *"Enabled: Yes"*) case "$out" in
        *"Server: 127.0.0.1"*) case "$out" in
          *"Port: $PORT"*) on=1 ;; esac ;; esac ;; esac
  done <<EOF
$(sys_services)
EOF
  if [ "$on" = "1" ]; then say "system proxy  on → 127.0.0.1:$PORT"
  else say "system proxy  off"; fi
}

cmd_off(){
  rm -f "$GUARD_DIR/proxy-want"
  pkill -f "proxy-mux.py" 2>/dev/null && say "mux stopped" || say "mux was not running"
  if [ -f "$SYSBASE" ]; then
    python3 - "$SYSBASE" <<'PY'
import json,subprocess,sys
d=json.load(open(sys.argv[1]))
for svc,v in d.items():
    for kind,flag in (("web","-setwebproxy"),("sec","-setsecurewebproxy")):
        st=(v.get(kind) or {})
        enabled=str(st.get("enabled","No")).lower()=="yes"
        server=st.get("server") or ""
        port=st.get("port") or "0"
        if enabled and server:
            subprocess.run(["networksetup",flag,svc,server,port],capture_output=True)
            subprocess.run(["networksetup",flag.replace("set","set")+"state",svc,"on"],capture_output=True)
        else:
            subprocess.run(["networksetup",flag.replace("set","set")+"state",svc,"off"],capture_output=True)
print("system proxy restored")
PY
    rm -f "$SYSBASE"
  fi
  python3 - "$STATE" <<'PY'
import json,sys,time
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
d.update({"up":False,"system":False,
          "rotations":d.get("rotations",0),"served":d.get("served",0),
          "failed":d.get("failed",0),"ts":int(time.time())})
json.dump(d,open(p,"w"),separators=(",",":"))
PY
}

cmd_rotate(){
  local want="${1:-next}" n=0 target=""
  case "$want" in
    next|'') target="next" ;;
    *) case "$want" in *[!0-9]*) err "rotate takes: next | <slot>"; exit 2 ;; esac
       target="$want" ;;
  esac
  if [ "$target" = "next" ]; then
    printf 'rotate\n' > "$CMD"
    sleep 1.2
  else
    # explicit slot: rewrite the pool order so that slot comes first
    python3 - "$POOL" "$target" <<'PY'
import sys
p,n=sys.argv[1],int(sys.argv[2])
lines=[l for l in open(p).read().splitlines()]
idx=[];i=0
for j,l in enumerate(lines):
    if l.strip() and not l.lstrip().startswith("#"):
        i+=1
        if i==n: idx.append(j)
if not idx: raise SystemExit(2)
j=idx[0]; row=lines.pop(j)
open(p,"w").write("\n".join([row]+lines).rstrip("\n")+"\n")
PY
    printf 'rotate\n' > "$CMD"
    sleep 1.2
  fi
  python3 -c "
import json,sys
try: d=json.load(open('$STATE'))
except Exception: d={}
print('current:', d.get('current'), '· pool', d.get('pool'), '· healthy', d.get('healthy'))" 2>/dev/null
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -x "$SELF_DIR/wall-log.sh" ] && bash "$SELF_DIR/wall-log.sh" proxy "slot $want" 2>/dev/null || true
}

# rotation policy lives in proxy.conf so it survives a mux restart and the HUD
# reads the same file the mux is obeying. no flag to remember, no drift.
cmd_policy(){
  local want="${1:-}"
  case "$want" in
  conn|window)
    { printf 'policy=%s\n' "$want"; [ "$want" = "window" ] && printf 'window=%s\n' "${2:-300}"; } > "$CONF"
    printf 'reload\n' > "$CMD" 2>/dev/null || true
    say "rotation policy → $want"
    ;;
  *)
    if [ -f "$CONF" ]; then sed 's/^/  /' "$CONF"; else say "  policy=conn (default)"; fi
    ;;
  esac
}

# the CLI's sockets are opened by `opencode.exe serve --service`, a child that
# inherits env at spawn. after PROXY ON, a service born earlier keeps going
# direct. this kills it so the CLI spawns a fresh one with the current env.
# pgrep cannot see it (session leader), so enumerate ps.
# the real auto-restart: the service is spawned by the CLI, so the only place
# that can guarantee its env is the binary path itself. a 2KB shim sits there,
# reads the mux state, exports the proxy vars, then execs the real binary. every
# future `serve --service` is born proxied even in a session that started
# before the proxy existed — no TUI restart, no stale env.
SHIM_MARK="opencode shim — born proxied"

# `command -v opencode` is usually the lane wrapper in ~/.local/bin, and the
# shim must sit at the *real* binary or the service spawn walks past it. try the
# known installs first, and refuse anything whose head looks like the lane.
shim_target(){
  local cand real
  for cand in "${OUC_REAL_BIN:-}" "$HOME/.npm-global/bin/opencode" \
              "$(command -v opencode 2>/dev/null)" \
              "$(npm root -g 2>/dev/null)/@opencode/cli/bin/opencode.exe"; do
    [ -n "$cand" ] || continue
    real=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$cand" 2>/dev/null)
    [ -n "$real" ] && [ -f "$real" ] || continue
    head -3 "$real" 2>/dev/null | grep -q "zen-lane\|OUC_REAL_BIN" && continue
    printf '%s' "$real"; return 0
  done
  return 1
}

cmd_shim(){
  local what="${1:-status}" tgt
  tgt=$(shim_target) || { err "no opencode binary on PATH"; exit 3; }
  case "$what" in
    status)
      if head -5 "$tgt" 2>/dev/null | grep -q "$SHIM_MARK"; then
        say "shim on — $tgt"
      elif [ -f "$tgt.real" ]; then
        say "shim was removed (real binary restored) — $tgt"
      else
        say "shim off — $tgt"
      fi
      ;;
    on)
      if head -5 "$tgt" 2>/dev/null | grep -q "$SHIM_MARK"; then
        say "shim already on — $tgt"; return 0
      fi
      [ -f "$tgt.real" ] || cp -p "$tgt" "$tgt.real" || { err "could not back up $tgt"; exit 4; }
      cp -p "$DEST/scripts/opencode.shim" "$tgt" 2>/dev/null || {
        err "shim source missing: $DEST/scripts/opencode.shim"; exit 4; }
      chmod +x "$tgt"
      say "shim installed at $tgt — every opencode process is born with the proxy env"
      ;;
    off)
      if [ -f "$tgt.real" ]; then
        cp -p "$tgt.real" "$tgt" && chmod +x "$tgt" \
          && say "real binary restored at $tgt"
      else
        say "no backup next to $tgt — nothing to restore"
      fi
      ;;
    *) err "usage: proxy-pool shim on|off|status"; exit 2 ;;
  esac
}

cmd_cli(){
  local n=0 p tgt
  # self-heal first: an npm update or a manual restore drops the shim, and then
  # a restart would spawn a direct service and look like the button is broken.
  if [ "$(count)" -gt 0 ] && tgt=$(shim_target); then
    head -5 "$tgt" 2>/dev/null | grep -q "$SHIM_MARK" || cmd_shim on >/dev/null 2>&1
  fi
  for p in $(ps -Ao pid=,args= 2>/dev/null | awk '/opencode[^ ]* serve --service/{print $1}'); do
    kill -TERM "$p" 2>/dev/null && n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    say "restarted $n cli service(s) — the next request spawns one with the current proxy env"
  else
    say "no cli service running — the next opencode launch takes the current env"
  fi
}

cmd_status(){  python3 - "$STATE" "$POOL" <<'PY'
import json,os,sys,time
state,pool=sys.argv[1],sys.argv[2]
try: d=json.load(open(state))
except Exception: d={}
n=sum(1 for l in open(pool) if l.strip() and not l.lstrip().startswith("#")) if os.path.exists(pool) else 0
up=d.get("up")
print("mux        %s%s" % ("up" if up else "down", (" · pid %s" % d["pid"]) if up else ""))
print("listen     %s" % d.get("listen","127.0.0.1:8899"))
print("current    %s" % (d.get("current") or "-"))
print("upstreams  %s · healthy %s" % (n, d.get("healthy","-")))
print("rotations  %s · served %s · failed %s" % (d.get("rotations",0), d.get("served",0), d.get("failed",0)))
print("system     %s" % ("on → 127.0.0.1" if d.get("system") else "off"))
if d.get("ts"):
    print("updated    %ss ago" % int(time.time()-d["ts"]))
PY
}

cmd_json(){
  python3 - "$STATE" "$POOL" "$HEALTH" <<'PY'
import json,os,subprocess,sys,time
state,pool,health=sys.argv[1:4]
try: d=json.load(open(state))
except Exception: d={"up":False}
try: h=json.load(open(health))
except Exception: h={}
rows=[];i=0
if os.path.exists(pool):
    for line in open(pool):
        line=line.strip()
        if not line or line.startswith("#"): continue
        i+=1
        k=line.split("://",1)[-1].split("@")[-1]
        e=h.get(k) or {}
        rows.append({"slot":i,"masked":line.split("://",1)[-1].split("@")[-1],
                     "state":e.get("state","unknown"),"ip":e.get("ip",""),
                     "bucket":e.get("bucket",""),"ms":e.get("ms",0)})
# does the CLI's long-lived service carry the proxy env? the lane exports it,
# but the service inherits env at spawn, so a service born before PROXY ON
# bypasses the mux entirely and burns quota while the sheet says "up".
cli=0
try:
    out=subprocess.run(["ps","-Ao","pid=,args="],capture_output=True,text=True,timeout=5).stdout
    for ln in out.splitlines():
        if "serve --service" in ln and "opencode" in ln:
            p_=ln.split(None,1)[0]
            env=subprocess.run(["ps","eww",p_],capture_output=True,text=True,timeout=5).stdout
            cli=1 if "HTTPS_PROXY=" in env else 2   # 1 routed, 2 stale
            break
except Exception:
    pass
d.update({"pool":len(rows),"upstreams":rows,"system":bool(d.get("system")),"cli":cli})
print(json.dumps(d,separators=(",",":")))
PY
}

case "${1:-status}" in
  add)     shift; cmd_add "${1:-}" ;;
  list|ls) cmd_list ;;
  remove|rm|del) shift; cmd_remove "${1:-}" ;;
  import)  shift; cmd_import "${1:-}" ;;
  cli|cli-restart) cmd_cli ;;
  shim) shift; cmd_shim "${1:-status}" ;;
  test|check) shift; cmd_test "${1:-}" ;;
  on|up)   cmd_on ;;
  sys)     shift; cmd_sys "${1:-}" ;;
  off|down) cmd_off ;;
  rotate)  shift; cmd_rotate "${1:-next}" ;;
  policy|pol) shift; cmd_policy "${1:-}" "${2:-300}" ;;
  status|st) cmd_status ;;
  json)    cmd_json ;;
  *)
    cat >&2 <<EOF
usage: proxy-pool add <host:port:user:pass> | list | test [n] | remove <n>
       proxy-pool on | off | sys [on|off] | rotate [next|<n>] | status | json

the client talks to 127.0.0.1:$PORT and never needs restarting.
EOF
    exit 2 ;;
esac
