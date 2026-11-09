#!/bin/bash
# api-keys — the OpenCode Console key pool, and the one that is live.
#
#   api-keys list           every OpenCode Console key, masked, active one marked
#   api-keys current        the key the CLI auth section uses right now
#   api-keys add <key>      add a key (dedupe by value, auto-label, cap 50)
#   api-keys remove <n|id>  remove by slot number or credential id
#   api-keys rotate [n]     make the next key (or slot n) active
#   api-keys json           machine-readable snapshot for status.sh / the HUD
#
# This is the same table `opencode auth list` reads: `credential`, rows with
# integration_id='opencode'. Exactly one row per integration has active=1 — that
# row is what the "OpenCode Console" entry in `opencode auth list` resolves to.
#
# The DB is WAL and opencode may hold it. Every write goes through a single
# sqlite transaction with an 8s busy timeout, so a live server never wedges us.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DEST/guard"
DB="${OUC_DB:-$HOME/.local/share/opencode/opencode.db}"
CAP="${OUC_KEY_CAP:-50}"
INTEGRATION="opencode"
SQLITE_ARGS=(-cmd ".timeout 8000")

say(){ printf '%s\n' "$*"; }
err(){ printf '%s\n' "$*" >&2; }

[ -f "$DB" ] || { err "no opencode db at $DB"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found"; exit 1; }

q(){ sqlite3 "${SQLITE_ARGS[@]}" "$DB" "$@"; }
# same, but tab-separated. the flag has to precede the db path or sqlite3
# parses it as SQL and returns nothing.
qs(){ sqlite3 -separator $'\t' "${SQLITE_ARGS[@]}" "$DB" "$@"; }

# ---------------------------------------------------------------- helpers

mask(){
  # oc_sk_27f9f4cd3509_Rsuc…zT — enough to recognise a key, not enough to use it
  local k="$1"
  local n=${#k}
  if [ "$n" -le 12 ]; then printf '%s…' "${k:0:4}"; return; fi
  printf '%s…%s' "${k:0:14}" "${k: -4}"
}

key_of(){  # pull .key out of the {"type":"key","key":"..."} value blob
  python3 - "$1" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1]); print(d.get("key",""))
except Exception:
    print("")
PY
}

now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }

# rows: id | label | value | active | time_created — ordered oldest first so
# the slot numbers are stable (slot 1 is the first key ever added).
rows(){
  qs "select id,label,value,coalesce(active,0),time_created
    from credential where integration_id='$INTEGRATION'
    order by time_created asc, id asc;"
}

count(){ q "select count(*) from credential where integration_id='$INTEGRATION';"; }

active_id(){ q "select id from credential where integration_id='$INTEGRATION' and active=1 limit 1;"; }

# ---------------------------------------------------------------- verbs

# collapses the pool to keys that can actually serve a request. removes
# duplicates (same key value stored twice) and keys the console rejects, so a
# rotation never lands on a row that lands the CLI on "Model unavailable".
cmd_prune(){
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local aid; aid=$(active_id)
  local dup=0 dead=0 id label value active created k fp
  local -a keep_ids=() drop_ids=()   # drop_ids: "id<TAB>label<TAB>why"
  local -A seen=()                   # key value -> "id|label" already kept

  # one pass over the pool: classify each row
  while IFS=$'\t' read -r id label value active created; do
    [ -n "$id" ] || continue
    k=$(key_of "$value")
    if [ -z "$k" ]; then
      drop_ids+=("$id"$'\t'"$label"$'\t'"unreadable")
      dup=$((dup+1))
      continue
    fi
    if [ -n "${seen["$k"]:-}" ]; then
      # the live row outranks an older twin: never delete what is authenticating
      if [ "$id" = "$aid" ]; then
        drop_ids+=("${seen["$k"]}"$'\t'"${seen["$k"]#*|}"$'\t'"duplicate of $label")
        seen["$k"]="$id|$label"
        dup=$((dup+1))
        keep_ids+=("$id")
        continue
      fi
      drop_ids+=("$id"$'\t'"$label"$'\t'"duplicate of ${seen["$k"]#*|}")
      dup=$((dup+1))
      continue
    fi
    seen["$k"]="$id|$label"
    probe_key "$k"
    local ph=$?
    if [ "$ph" = "2" ] && [ -n "$aid" ]; then
      # ambiguous (hang / 429). settle it against the key that works right now:
      # if the incumbent answers, this row is the problem, not the network.
      local ak; ak=$(key_of "$(q "select value from credential where id='${aid//\'/\'\'}';")")
      if [ -n "$ak" ]; then
        probe_key "$ak"
        if [ $? = 0 ]; then
          probe_key "$k"; ph=$?
          [ "$ph" = "2" ] && ph=1
        fi
      fi
    fi
    if [ "$ph" = "1" ]; then
      drop_ids+=("$id"$'\t'"$label"$'\t'"rejected")
      dead=$((dead+1))
      continue
    fi
    keep_ids+=("$id")
  done < <(rows)

  if [ "${#drop_ids[@]}" = "0" ]; then
    say "pool is clean — $(count) keys, none duplicated or rejected."
    return 0
  fi

  local rec why
  for rec in "${drop_ids[@]}"; do
    id="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
    label="${rec%%$'\t'*}"; why="${rec#*$'\t'}"
    if [ "$dry" = "1" ]; then
      say "would remove \"$label\" ($why)"
    else
      q "delete from credential where id='${id//\'/\'\'}';" &&
        say "removed \"$label\" ($why)"
    fi
  done

  if [ "$dry" = "1" ]; then
    printf '%d removable · %d duplicate · %d rejected · %d left\n' \
      "${#drop_ids[@]}" "$dup" "$dead" "$(count)"
    return 0
  fi

  # the active row may have been one of the casualties: promote a live one
  if [ -z "$(active_id)" ]; then
    local cid cvalue ck
    while IFS=$'\t' read -r cid _ cvalue _ _; do
      [ -n "$cid" ] || continue
      ck=$(key_of "$cvalue")
      probe_cached "$ck"
      if [ $? != 1 ]; then
        set_active "$cid" && say "active key → \"$(q "select label from credential where id='${cid//\'/\'\'}';")\""
        break
      fi
    done < <(rows)
  fi

  printf '%d removed · %d duplicate · %d rejected · %d left\n' \
    "${#drop_ids[@]}" "$dup" "$dead" "$(count)"
}

cmd_list(){
  local n; n=$(count)
  local aid; aid=$(active_id)
  local i=0
  printf '%-4s %-6s %-22s %s\n' "#" "ACTIVE" "LABEL" "KEY"
  while IFS=$'\t' read -r id label value active _; do
    i=$((i+1))
    [ -n "$id" ] || continue
    local k; k=$(key_of "$value")
    local flag=""; [ "$id" = "$aid" ] && flag="  ←"
    printf '%-4s %-6s %-22s %s%s\n' "$i" "$([ "$active" = "1" ] && echo "*" || echo "-")" "$label" "$(mask "$k")" "$flag"
  done < <(rows)
  printf '\n%d / %d keys.\n' "$n" "$CAP"
  if [ "$n" -ge "$CAP" ]; then
    say "pool is full — remove one before adding another."
  fi
}

cmd_current(){
  local aid; aid=$(active_id)
  if [ -z "$aid" ]; then
    say "no active OpenCode Console key"
    return 1
  fi
  local row; row=$(qs "select label,value from credential where id='$aid';")
  local label="${row%%$'\t'*}"; local value="${row#*$'\t'}"
  local k; k=$(key_of "$value")
  printf '%s\t%s\t%s\n' "$label" "$aid" "$(mask "$k")"
}

# validate a key before it is stored: opencode console keys look like
# oc_sk_<12 hex>_<base64-ish>. reject anything that cannot be one, and reject
# whitespace/control bytes outright (they would corrupt the shell arg and json).
valid_key(){
  local k="$1"
  [ -n "$k" ] || return 1
  case "$k" in
    *[[:space:]]*) return 1 ;;
  esac
  # 20..200 chars, printable
  local n=${#k}
  [ "$n" -ge 20 ] && [ "$n" -le 200 ] || return 1
  return 0
}

# the same endpoint the CLI's Console provider calls, with the same bearer
# scheme. 2xx = the key works and the console has models for it. any auth
# error = the key is dead and would land you on "Model unavailable".
ZEN="https://opencode.ai/inference/openai/v1/models"
probe_key(){
  local k="$1" code
  [ -n "$k" ] || return 1
  code=$(curl -s -o /dev/null --connect-timeout 4 --max-time 12 \
    -H "Authorization: Bearer $k" -w '%{http_code}' "$ZEN" 2>/dev/null)
  case "$code" in
    2*)      return 0 ;;                 # live
    401|403) return 1 ;;                 # the key itself is rejected
    '')      return 2 ;;                 # network down — unknown
    *)       return 2 ;;                 # 429/5xx: console busy — unknown, not dead
  esac
}

# `/models` answering 200 only means the key is valid — it says nothing about
# whether that key still has free quota. rotating onto a capped key is the exact
# path that surfaces as "Model unavailable" in the CLI, because the provider
# rejects the model call instead of the credential. so ask the model itself,
# one token, and treat 429/402 as "capped", not "dead" and not "fine".
QUOTA_BASE="${ZEN%/models}"
probe_model(){
  local k="$1" model="${2:-}" code
  [ -n "$k" ] && [ -n "$model" ] || return 2
  code=$(curl -s -o /dev/null --connect-timeout 4 --max-time 14 \
    -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
    -w '%{http_code}' "$QUOTA_BASE/chat/completions" 2>/dev/null)
  case "$code" in
    2*)      return 0 ;;                 # the model answers
    429|402) return 1 ;;                 # free wall / no credit
    401|403) return 3 ;;                 # credential rejected
    400)     return 4 ;;                 # "Model is unavailable" upstream
    '')      return 2 ;;                 # network
    *)       return 2 ;;                 # 5xx and friends: unknown
  esac
}

# which model is pinned, and on which provider — a rotation has to keep the
# credential pool aligned with the model or it swaps the CLI off its provider.
pinned_model(){
  python3 - "$HOME/.config/opencode/opencode.json" <<'PY2' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
m=d.get("model") or ""
print(m)
PY2
}

# hitting /models right after a rotation fills the CLI's per-credential console
# cache. otherwise the next prompt pays that fetch, and a slow one surfaces as
# "Model unavailable".
warm_console(){
  local k="$1"
  [ -n "$k" ] || return 0
  curl -s -o /dev/null --connect-timeout 4 --max-time 15 \
    -H "Authorization: Bearer $k" "$ZEN" 2>/dev/null || true
}

cmd_health(){
  local i=0 aid; aid=$(active_id)
  printf '%-3s %-17.17s %-7s %s\n' "#" "LABEL" "STATE" "KEY"
  while IFS=$'\t' read -r id label value active _; do
    [ -n "$id" ] || continue
    i=$((i+1))
    local k; k=$(key_of "$value")
    local st ph fp
    probe_key "$k"; ph=$?
    fp=$(printf '%s' "$k" | shasum -a 256 | cut -c1-16)
    # `check` is the verb that settles the pool, so it has to record what it
    # saw. a health check that probes but does not write leaves list, rotate
    # and the HUD trusting a stale "live" from before the key was revoked —
    # which is exactly how nine 401s kept a green dot.
    [ "$ph" = "2" ] || _probe_read "$fp" set "$ph"
    case $ph in
      0) st="live" ;;
      1) st="DEAD" ;;
      *) st="unknown" ;;
    esac
    [ "$id" = "$aid" ] && st="$st *"
    # the console pane in the HUD is ~48 columns wide. a full mask wrapped
    # every row onto two lines, which read as noise. short form fits.
    local short; [ ${#k} -gt 16 ] && short="${k:0:8}…${k: -4}" || short="$k"
    printf '%-3s %-17.17s %-7s %s\n' "$i" "$label" "$st" "$short"
  done < <(rows)
}

PROBE_CACHE="$GUARD/key-probe.json"

# one probe per key per 10 minutes. ten rotations in a row must not become ten
# HTTP round trips, and hammering the endpoint is what earns a 429 — which the
# old code then read as "dead key".
_probe_read(){
  PROBE_CACHE="$PROBE_CACHE" FP="$1" MODE="$2" ST="${3:-0}" python3 - "$PROBE_CACHE" "$1" "$2" "${3:-0}" <<'PY' 2>/dev/null
import json, os, sys, time
path, fp, mode, st = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try: d = json.load(open(path))
except Exception: d = {}
if mode == "age":
    e = d.get(fp)
    print(int(time.time() - e["ts"]) if e else -1)
elif mode == "get":
    print((d.get(fp) or {}).get("st", 2))
else:
    d[fp] = {"ts": int(time.time()), "st": st}
    d = {k: v for k, v in list(d.items())[-200:]}
    try: json.dump(d, open(path, "w"))
    except Exception: pass
PY
}

# how long a verdict may be trusted depends on which verdict it is. a rejected
# key does not come back, so caching that for ten minutes is free. a live key
# can be revoked at any moment, and a ten-minute "live" cache is exactly how a
# pool of nine revoked keys still painted a green dot — every one of them was
# answering 401 while the cache insisted otherwise.
PROBE_ALIVE_TTL=60
PROBE_DEAD_TTL=600

probe_cached(){
  local k="$1" fp age st ttl
  fp=$(printf '%s' "$k" | shasum -a 256 | cut -c1-16)
  age=$(_probe_read "$fp" age)
  case "$age" in ''|*[!0-9-]*) age=-1 ;; esac
  if [ "$age" -ge 0 ]; then
    st=$(_probe_read "$fp" get); case "$st" in ''|*[!0-9]*) st=2 ;; esac
    case "$st" in
      0) ttl=$PROBE_ALIVE_TTL ;;
      1) ttl=$PROBE_DEAD_TTL ;;
      *) ttl=0 ;;
    esac
    if [ "$age" -lt "$ttl" ]; then return "$st"; fi
  fi
  probe_key "$k"; st=$?
  [ "$st" = "2" ] || _probe_read "$fp" set "$st"
  return "$st"
}

cmd_add(){
  local raw="${1:-}"
  # tolerate an accidental "OpenCode Console" paste or surrounding quotes
  raw="${raw%$'\r'}"
  raw="${raw#\"}"; raw="${raw%\"}"
  raw="${raw#\'}"; raw="${raw%\'}"
  if ! valid_key "$raw"; then
    err "not a usable key (expected a single token, 20-200 printable chars)"
    exit 2
  fi

  # never store a key that cannot serve a model list: that is exactly the key
  # that produces "Model unavailable" ten seconds into a prompt.
  probe_cached "$raw"; local ph=$?
  if [ "$ph" = "1" ]; then
    err "key rejected by the console (401/403) — not added"
    exit 6
  fi
  [ "$ph" = "2" ] && say "network is down — adding without a liveness check."

  local n; n=$(count)
  # dedupe by exact key value anywhere in the pool
  local dup; dup=$(q "select label from credential where integration_id='$INTEGRATION' and value like '%' || replace('$raw','''','''''') || '%' limit 1;")
  # like-match is fuzzy (json escaping) — confirm with a real parse
  dup=$(rows | python3 -c '
import json,sys
want=sys.argv[1]
for line in sys.stdin:
    parts=line.rstrip("\n").split("\t")
    if len(parts)<3: continue
    try: k=json.loads(parts[2]).get("key","")
    except Exception: k=""
    if k==want:
        print(parts[1]); break
' "$raw")
  if [ -n "$dup" ]; then
    say "already in the pool as \"$dup\" — nothing added."
    return 0
  fi

  if [ "$n" -ge "$CAP" ]; then
    err "pool is full ($n/$CAP) — remove one first: api-keys remove <n>"
    exit 3
  fi

  # next free label number
  local next; next=$(q "select coalesce(max(cast(substr(label, length('OpenCode Console ')+1) as integer)),0)+1
    from credential where integration_id='$INTEGRATION' and label like 'OpenCode Console %';")
  [ -n "$next" ] || next=1
  local label="OpenCode Console $next"
  local id="cred_$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
  local ts; ts=$(now_ms)
  local blob; blob=$(python3 -c 'import json,sys;print(json.dumps({"type":"key","key":sys.argv[1]},separators=(",",":")))' "$raw")

  # insert inactive; rotation is a separate explicit act. escape single quotes
  local sid="${id//\'/\'\'}" slab="${label//\'/\'\'}" sblob="${blob//\'/\'\'}"
  if ! q "insert into credential (id,integration_id,label,value,connector_id,method_id,active,time_created,time_updated)
          values ('$sid','$INTEGRATION','$slab','$sblob',null,null,0,$ts,$ts);"; then
    err "insert failed"
    exit 4
  fi
  printf 'added "%s" (%s) — %d/%d. make it live with: api-keys rotate\n' "$label" "$(mask "$raw")" "$((n+1))" "$CAP"
}

set_active(){
  local id="$1"
  local sid="${id//\'/\'\'}"
  local ts; ts=$(now_ms)
  q "begin immediate;
     update credential set active=0 where integration_id='$INTEGRATION';
     update credential set active=1, time_updated=$ts where id='$sid' and integration_id='$INTEGRATION';
     commit;" || return 1
  [ "$(active_id)" = "$id" ] || return 1
  return 0
}

cmd_remove(){
  local want="${1:-}"
  if [ -z "$want" ]; then err "usage: api-keys remove <slot|credid>"; exit 2; fi
  local id=""
  if [ "${want:0:5}" = "cred_" ]; then
    id=$(q "select id from credential where id='${want//\'/\'\'}' and integration_id='$INTEGRATION';")
  else
    case "$want" in
      *[!0-9]*) err "slot must be a number"; exit 2 ;;
    esac
    id=$(rows | awk -F'\t' -v n="$want" 'NR==n{print $1}')
  fi
  [ -n "$id" ] || { err "no such key: $want"; exit 4; }
  local was_active; was_active=$([ "$id" = "$(active_id)" ] && echo 1 || echo 0)
  local label; label=$(q "select label from credential where id='$id';")
  q "delete from credential where id='$id';" || { err "delete failed"; exit 4; }
  say "removed \"$label\""
  if [ "$was_active" = "1" ]; then
    # promote a key that actually answers, not merely the newest row
    local cid ck ph nid=""
    while IFS=$'\t' read -r cid _; do
      [ -n "$cid" ] || continue
      ck=$(key_of "$(q "select value from credential where id='$cid';")")
      probe_cached "$ck"; ph=$?
      if [ "$ph" != "1" ]; then nid="$cid"; break; fi
      say "not promoting \"$(q "select label from credential where id='$cid';")\" — the console will not serve it"
    done < <(rows)
    if [ -n "$nid" ]; then
      set_active "$nid" && say "promoted \"$(q "select label from credential where id='$nid';")\" to active."
    else
      say "no usable key left — add one to restore auth."
    fi
  fi
}

cmd_rotate(){
  local want="${1:-}"
  local aid; aid=$(active_id)

  # the pool in slot order. rotation walks this list, so "next" and "prev" are
  # the same code with a different step sign.
  local -a ids=()
  local id
  while IFS=$'\t' read -r id _; do [ -n "$id" ] && ids+=("$id"); done < <(rows)
  local n=${#ids[@]}
  [ "$n" -gt 0 ] || { err "pool is empty — add a key first"; exit 4; }

  # index of the live key (or -1)
  local cur=-1 i
  for i in 0 $((n-1)); do :; done
  for ((i=0; i<n; i++)); do [ "${ids[$i]}" = "$aid" ] && cur=$i; done

  local start_idx=-1
  case "$want" in
    ""|next|fwd|+)   start_idx=$(( (cur + 1 + n) % n )) ;;
    prev|back|-)     start_idx=$(( (cur - 1 + n) % n )) ;;
    cred_*)
      for ((i=0; i<n; i++)); do [ "${ids[$i]}" = "$want" ] && start_idx=$i; done
      [ "$start_idx" -ge 0 ] || { err "no such key: $want"; exit 4; }
      ;;
    *)
      case "$want" in
        *[!0-9]*) err "rotation target must be next, prev, a slot number or a credential id"; exit 2 ;;
      esac
      [ "$want" -ge 1 ] && [ "$want" -le "$n" ] || { err "no such slot: $want"; exit 4; }
      start_idx=$(( want - 1 ))
      ;;
  esac

  # walk from the start index in the requested direction, skipping only keys
  # the console actually rejects. 0 = live, 2 = unknown (console busy / offline)
  # and is allowed through; 1 = rejected.
  local step=1
  case "$want" in prev|back|-) step=-1 ;; esac
  [ "$start_idx" -ge 0 ] || step=1

  MODEL_PIN=$(pinned_model)
  # before walking: if every key reports the same verdict for the pinned model,
  # rotating is theatre. one pass tells us, and it stops the "rotated but the
  # wall stayed" loop that looks like a broken rotation.
  MODEL_PIN=$(pinned_model)
  # the pool only owns the console provider. a model pinned to another provider
  # (river, etc.) has nothing to do with these credentials, and probing it here
  # is how rotation got blocked by a working session.
  MODEL_PROV="${MODEL_PIN%%/*}"
  [ -n "$MODEL_PROV" ] || MODEL_PROV="$INTEGRATION"
  if [ -n "$MODEL_PIN" ] && [ "$MODEL_PROV" = "$INTEGRATION" ]; then
    local m samp verdict=""
    m="${MODEL_PIN#*/}"
    local verdicts=""
    while IFS=$'\t' read -r id _ value active; do
      [ -n "$id" ] || continue
      probe_model "$(key_of "$value")" "$m"
      verdicts="$verdicts$?"
    done < <(rows)
    # all identical and not "ok" -> the pool shares one wall
    case "$verdicts" in
      ''|*'0'*) : ;;
      *)
        case "$verdicts" in
          *[!0]*) ;;
        esac
        local first="${verdicts:0:1}" same=1 c
        for ((c=0; c<${#verdicts}; c++)); do
          [ "${verdicts:$c:1}" = "$first" ] || same=0
        done
        if [ "$same" = "1" ]; then
          case "$first" in
            1) say "every key reports the same free wall for $m — this pool shares one quota, rotation cannot bypass it" ;;
            4) say "every key reports $m as unavailable — that is the model, not the key" ;;
            *) say "every key reports $m as $first — rotation would change nothing" ;;
          esac
          say "try: model-levers set <provider>/<model> (a provider model), or wait for the reset"
          return 0
        fi
        ;;
    esac
  fi

  local target="" idx="$start_idx" seen
  for ((seen=0; seen<n; seen++)); do
    local cand="${ids[$(( (idx + n) % n ))]}"
    local ck; ck=$(key_of "$(q "select value from credential where id='${cand//\'/\'\'}';")")
    probe_cached "$ck"; local ph=$?
    if [ "$ph" = "2" ] && [ -n "$aid" ]; then
      # ambiguous — settle it against the key that works right now
      local ak; ak=$(key_of "$(q "select value from credential where id='$aid';")")
      if [ -n "$ak" ]; then probe_key "$ak"; [ $? = 0 ] && ph=1; fi
    fi
    if [ "$ph" != "1" ]; then target="$cand"; break; fi
    local cl; cl=$(q "select label from credential where id='$cand';")
    say "skipping \"$cl\" — the console will not serve it"
    idx=$(( (idx + step + n) % n ))
  done
  if [ -z "$target" ]; then
    if [ -n "$MODEL_PIN" ]; then
      err "every key in the pool is at the free wall for ${MODEL_PIN#*/} — rotate the model (HUD → PROXY → MODELS) or add a key with quota"
    else
      err "every key in the pool is rejected — add a working one"
    fi
    exit 7
  fi

  if [ "$target" = "$aid" ]; then
    local lbl; lbl=$(q "select label from credential where id='$target';")
    say "already live: \"$lbl\""
    return 0
  fi

  if ! set_active "$target"; then
    err "rotation write failed"
    exit 5
  fi
  local lbl; lbl=$(q "select label from credential where id='$target';")
  local val valk; val=$(q "select value from credential where id='$target';"); valk=$(key_of "$val")
  warm_console "$valk"
  printf 'rotated → "%s" (%s)\n' "$lbl" "$(mask "$valk")"

  # the CLI caches the console model list per credential id. swapping the active
  # row invalidates that cache, and the refetch is what surfaced as
  # "Model unavailable" for the next few seconds. touching the config makes it
  # rebuild providers immediately instead of on the user's next prompt.
  cfg="$HOME/.config/opencode/opencode.json"
  if [ -f "$cfg" ]; then
    touch "$cfg" 2>/dev/null && say "provider reload requested"
  fi

  # a rotated key is not a rotated quota. ask the model on the new key: if it
  # answers 429 the wall is account-wide and no amount of key shuffling helps,
  # so say that here rather than letting the CLI surface it as a model error.
  if [ -n "${MODEL_PIN:-}" ] && [ "${MODEL_PROV:-$INTEGRATION}" = "$INTEGRATION" ]; then
    probe_model "$valk" "${MODEL_PIN#*/}"; local qr=$?
    case $qr in
      0) say "quota ok on ${MODEL_PIN#*/}" ;;
      *)
        # a rotated key that cannot serve the model is a rotated error, not a
        # fix. move the model to one the console is actually serving; if none
        # is, say the true thing instead of handing back a broken session.
        say "${MODEL_PIN#*/} does not answer on the new key — looking for a model that does"
        if [ -x "$SELF_DIR/model-levers.sh" ]; then
          local code2 try=0 nm m2 q2
          [ "$qr" = "4" ] && code2=400 || code2=429
          bash "$SELF_DIR/model-levers.sh" dead "${MODEL_PIN#*/}" "$code2" >/dev/null 2>&1
          # `next` only knows what has been probed, so verify each pick before
          # handing it over. three tries, then say the pool is out.
          while [ "$try" -lt 3 ]; do
            try=$((try + 1))
            nm=$(bash "$SELF_DIR/model-levers.sh" next 2>/dev/null | tail -1)
            [ -n "$nm" ] || break
            m2="${nm#*/}"
            probe_model "$valk" "$m2"; q2=$?
            case "$q2" in
              0) say "switched model → $nm (answers on the new key)"; nm="$nm"; break ;;
              4) bash "$SELF_DIR/model-levers.sh" dead "$m2" 400 >/dev/null 2>&1 ;;
              1) bash "$SELF_DIR/model-levers.sh" dead "$m2" 429 >/dev/null 2>&1 ;;
              *) nm="" ;;
            esac
            nm=""
          done
          if [ -z "${nm:-}" ]; then
            bash "$SELF_DIR/model-levers.sh" set "${MODEL_PIN#*/}" >/dev/null 2>&1 \
              && say "left the model on ${MODEL_PIN#*/} — no free model answered"
            say "no free model answers right now — the opencode free pool is exhausted account-wide; key rotation cannot bypass it. Use a provider model or wait for the reset."
          fi
        fi
        ;;
    esac
  fi
}

# one pass over the pool for the pinned model: how many keys answer, how many
# are at the wall, how many do not serve it. rotation is only worth anything if
# these numbers differ per key.
cmd_quota(){
  local model="${1:-}"
  [ -n "$model" ] || model=$(pinned_model)
  [ -n "$model" ] || { err "no pinned model — model-levers set <id>"; exit 2; }
  local m="${model#*/}" ok=0 wall=0 gone=0 dead=0 i=0 id label k code r
  printf '%-18s %-10s %s\n' "LABEL" "STATE" "MODEL"
  while IFS=$'\t' read -r id label value active; do
    [ -n "$id" ] || continue
    i=$((i+1))
    k=$(key_of "$value")
    probe_model "$k" "$m"; r=$?
    case "$r" in
      0) ok=$((ok+1));   printf '%-18s %-10s %s\n' "$label" "ok" "$m" ;;
      1) wall=$((wall+1)); printf '%-18s %-10s %s\n' "$label" "wall" "$m" ;;
      3) dead=$((dead+1)); printf '%-18s %-10s %s\n' "$label" "rejected" "$m" ;;
      4) gone=$((gone+1)); printf '%-18s %-10s %s\n' "$label" "unavailable" "$m" ;;
      *) printf '%-18s %-10s %s\n' "$label" "?" "$m" ;;
    esac
  done < <(rows)
  say ""
  say "$ok ok · $wall wall · $gone unavailable · $dead rejected"
  if [ "$ok" = "0" ] && [ "$wall" -gt 1 ]; then
    say "every key reports the same wall — the free quota is account-wide, key rotation cannot bypass it"
  fi
  [ "$ok" -gt 0 ]
}

cmd_json(){
  local data; data=$(rows)
  printf '%s\n' "$data" | python3 -c '
import json,sys,time,hashlib,os
cap=int(sys.argv[1]); probe=sys.argv[2]
try: cache=json.load(open(probe))
except Exception: cache={}
def verdict(raw):
    if not raw: return "unknown"
    e=cache.get(hashlib.sha256(raw.encode()).hexdigest()[:16])
    if not e: return "unknown"
    try: age=time.time()-float(e.get("ts") or 0)
    except Exception: return "unknown"
    st=e.get("st")
    if st==0 and age<60: return "live"
    if st==1: return "dead"
    return "unknown"
rows=[]
for line in sys.stdin:
    parts=line.rstrip("\n").split("\t")
    if len(parts)<5: continue
    cid,label,value,active,created=parts[:5]
    try: key=json.loads(value).get("key","")
    except Exception: key=""
    masked=(key[:14]+"\u2026"+key[-4:]) if len(key)>18 else (key[:4]+"\u2026" if key else "")
    rows.append({"id":cid,"label":label,"masked":masked,"state":verdict(key),
                 "active":active.strip()=="1","created":int(created or 0)})
cur=next((r for r in rows if r["active"]),None)
cnt={s:sum(1 for r in rows if r["state"]==s) for s in ("live","dead","unknown")}
print(json.dumps({"count":len(rows),"cap":cap,"active":cur["label"] if cur else None,
                  "activeMasked":cur["masked"] if cur else None,
                  "activeLive":(cur["state"]=="live") if cur else None,
                  "live":cnt["live"],"dead":cnt["dead"],"unknown":cnt["unknown"],
                  "keys":rows}, separators=(",",":")))
' "$CAP" "$PROBE_CACHE"
}

case "${1:-list}" in
  list|ls)         cmd_list ;;
  current|cur)     cmd_current ;;
  add)             shift; cmd_add "${1:-}" ;;
  remove|rm|del)   shift; cmd_remove "${1:-}" ;;
  rotate|next|hop) shift; cmd_rotate "${1:-}" ;;
  health|probe)    cmd_health ;;
  quota)           shift; cmd_quota "${1:-}" ;;
  prune|clean)     cmd_prune "${2:-}" ;;
  json)            cmd_json ;;
  *)
    cat >&2 <<EOF
usage: api-keys list|current|health|quota [model]|add <key>|remove <slot|id>|rotate [next|prev|slot|id]|prune [--dry-run]|json
       pool cap: $CAP keys (OUC_KEY_CAP to change)
EOF
    exit 2 ;;
esac
