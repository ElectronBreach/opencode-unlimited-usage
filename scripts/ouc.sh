#!/bin/bash
# ouc — one entry point for the whole opencode-unlimited install.
#
#   ouc                 status snapshot (the default)
#   ouc status [--json] live state: tunnel, egress, tokens, keys
#   ouc doctor          health check, one line per subsystem
#   ouc audit           feature audit against the linux upstream
#   ouc keys <verb>     list | current | health | add <k> | remove <id> | rotate [next|prev|slot|id] | prune
#   ouc hud <verb>      show | summon | hide | quit | toggle | collapse | expand | reload | warp
#   ouc hop             force a fresh identity now
#   ouc logs [which]    tail keeper | guard | overlay | lane
#   ouc paths           print every file this install owns
#   ouc version         installed version and payload checksum
#
# everything here is a thin wrapper: there is no logic in this file that the
# individual scripts do not already own.
set -u
BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
S="$DEST/scripts"
G="$DEST/guard"

die(){ printf '%s\n' "$*" >&2; exit 2; }
need(){ [ -x "$S/$1" ] || die "$1 is not installed — run the installer"; }

case "${1:-status}" in
  status)
    need status.sh
    shift || true
    exec "$S/status.sh" "$@"
    ;;
  doctor)
    need doctor.sh
    shift || true
    exec "$S/doctor.sh" "$@"
    ;;
  audit)
    need audit.sh
    shift || true
    exec "$S/audit.sh" "$@"
    ;;
  keys|key)
    need api-keys.sh
    shift || true
    exec "$S/api-keys.sh" "$@"
    ;;
  hud|overlay)
    need overlay-ctl.sh
    shift || true
    exec "$S/overlay-ctl.sh" "$@"
    ;;
  hop)
    need zen-hop.sh
    shift || true
    exec "$S/zen-hop.sh" "$@"
    ;;
  logs|log)
    which="${2:-keeper}"
    case "$which" in
      keeper)  f="$G/keeper.log" ;;
      guard)   f="$G/guard-daemon.log" ;;
      overlay) f="$G/overlay-crash.log" ;;
      lane)    f="$G/lane.log" ;;
      *)       die "no such log: $which (keeper|guard|overlay|lane)" ;;
    esac
    [ -f "$f" ] || die "no log at $f"
    exec tail -n "${3:-40}" -f "$f"
    ;;
  paths)
    for f in "$DEST" "$DEST/scripts" "$DEST/guard" \
             "$HOME/Library/LaunchAgents/com.$BRAND.overlay.plist" \
             "$HOME/Library/LaunchAgents/com.$BRAND.guard.plist" \
             "/Library/LaunchDaemons/com.$BRAND.keeper.plist" \
             "$HOME/.local/bin/opencode" "$HOME/.local/bin/ouc" \
             "/etc/sudoers.d/$BRAND" "$HOME/.opencode/AGENTS.md"; do
      [ -e "$f" ] && printf '  %s\n' "$f" || printf '  %s  (missing)\n' "$f"
    done
    ;;
  version)
    v="unknown"; [ -f "$DEST/VERSION" ] && v=$(cat "$DEST/VERSION")
    printf '  %s %s\n' "$BRAND" "$v"
    if [ -f "$DEST/payload-sha" ]; then
      printf '  payload %s\n' "$(cut -c1-16 "$DEST/payload-sha")"
    fi
    ;;
  help|-h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "unknown command: $1 — try: ouc help"
    ;;
esac
