#!/bin/bash
# warp-gui-heal — the enrollment sheet is a GUI lie, not a tunnel problem.
#
# after a rotation the client re-registers, and the WARP window can come back
# as "Enroll your device / Checking your organization configuration…" while
# `warp-cli status` is Connected and egress works. the daemon is fine; the
# window is stale state in the front-end. relaunching the *GUI* (never the root
# daemon) clears it, and the tunnel never blinks.
#
# exit 0 = nothing to do, 1 = healed, 2 = GUI missing (caller may open it)
set -u

APP="/Applications/Cloudflare WARP.app"
open_gui(){ open -g -a "$APP" >/dev/null 2>&1 || open -a "$APP" >/dev/null 2>&1; }

running(){ pgrep -f "$APP/Contents/MacOS/Cloudflare WARP" >/dev/null 2>&1; }

running || { open_gui; exit 2; }

# read the visible window titles; the enrollment page always carries its heading
win_titles=$(
  osascript <<'AS' 2>/dev/null
tell application "System Events"
  if not (exists process "Cloudflare WARP") then return ""
  tell process "Cloudflare WARP"
    set out to ""
    repeat with w in windows
      try
        set out to out & (name of w) & "|"
      end try
    end repeat
    return out
  end tell
end tell
AS
)

stuck=0
case "$win_titles" in
  *"Cloudflare One"*|*Enroll*|*nroll*) stuck=1 ;;
esac

# the title alone is not always set; check the first static text when a window
# exists at all. this is the string that only appears on the enrollment page.
if [ "$stuck" = "0" ] && [ -n "$win_titles" ]; then
  body=$(
    osascript <<'AS' 2>/dev/null
tell application "System Events"
  tell process "Cloudflare WARP"
    try
      return value of static text 1 of window 1
    end try
  end tell
  return ""
end tell
AS
)
  case "$body" in
    *Enroll*|*organization\ configuration*|*Cloudflare\ One*) stuck=1 ;;
  esac
fi

[ "$stuck" = "1" ] || exit 0

# a stale front-end: quit the app (not the daemon), let launchd/the keeper keep
# the tunnel, then reopen. two tries, because a slow quit leaves the old window.
for i in 1 2; do
  osascript -e 'tell application "Cloudflare WARP" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -f "$APP/Contents/MacOS/Cloudflare WARP" >/dev/null 2>&1 || true
  sleep 1
  open_gui
  sleep 2
  running && break
done
exit 1
