#!/bin/bash
# zen hop — manual identity rotation. deletes the current warp registration,
# registers fresh, reconnects. you land on a new IPv6 /64 (= new quota bucket).
#
# the keeper is paused during the hop — otherwise its 45s tick races us and
# "helpfully" repairs the tunnel mid-surgery. the kill-switch chain stays
# installed the whole time (keeper owns it but doesn't remove it on stop),
# so there is no leak window. keeper resumes on exit no matter what.
set -u

WARP="$(command -v warp-cli || echo /usr/bin/warp-cli)"
[ -x "$WARP" ] || WARP="$HOME/.local/bin/warp-cli"
[ -x "$WARP" ] || { echo "warp-cli not found"; exit 1; }

KEEPER="${OUC_KEEPER_UNIT:-opencode-unlimited-keeper}"
W="sudo -n $WARP --accept-tos"

# if passwordless warp-cli isn't set up, fall back to normal sudo
$W status >/dev/null 2>&1 || W="sudo $WARP --accept-tos"

restore(){ sudo -n systemctl start "$KEEPER" >/dev/null 2>&1 || sudo systemctl start "$KEEPER" >/dev/null 2>&1; }
trap restore EXIT

cur_v6(){ timeout 10 curl -s -m 8 https://api64.ipify.org 2>/dev/null; }

OLD_V6=$(cur_v6)
echo "old /64: ${OLD_V6:-?}"

sudo systemctl stop "$KEEPER" >/dev/null 2>&1
echo "-- rotating (keeper paused) --"
$W disconnect         >/dev/null 2>&1
$W registration delete >/dev/null 2>&1
NEW=0
for i in 1 2 3 4 5; do
  $W registration new >/dev/null 2>&1 && { NEW=1; break; }
  echo "  attempt $i failed"; sleep 8
done
[ "$NEW" = 1 ] || { echo "-- registration failed — keeper will keep retrying --"; exit 1; }
$W mode warp >/dev/null 2>&1
$W connect   >/dev/null 2>&1

for i in $(seq 1 20); do
  sleep 3
  $W status 2>/dev/null | head -1 | grep -q Connected && break
done

NEW_V6=$(cur_v6)
echo "new /64: ${NEW_V6:-?}"
if [ "$NEW_V6" != "$OLD_V6" ] && [ -n "$NEW_V6" ]; then
  echo "== FRESH /64 ✓ — re-send your message =="
  exit 0
fi
echo "== cloudflare handed back the same block — run me again =="
exit 1
