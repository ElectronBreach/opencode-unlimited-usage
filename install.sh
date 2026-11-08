#!/bin/bash
# Opencode Unlimited Usage — installer (macOS port)
#
# ONE SHOT: opencode + cloudflare warp (brew cask) + launchd keeper + guard +
# lane shim + credit enforcement + self-verify. you run one line, you get a
# working system.
#
# macOS differences from the linux build, stated plainly:
#   * launchd replaces systemd (root LaunchDaemon + user LaunchAgent)
#   * pf replaces iptables, and the leak guard is FAIL-OPEN: rules exist only
#     while the tunnel is actually up, so a dead tunnel can never take the
#     Mac offline (that was the previous failure)
#   * no mount namespaces: the lane pins /etc/hosts for the duration of the
#     launch and always restores it
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
GUARD_DIR="$DEST/guard"
DAEMON_LABEL="com.opencode-unlimited.keeper"
AGENT_LABEL="com.opencode-unlimited.guard"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
SHIM="$HOME/.local/bin/opencode"
SUDOERS_FILE="/etc/sudoers.d/$BRAND"
REPO="https://github.com/ElectronBreach/opencode-unlimited-usage"
RAW="https://raw.githubusercontent.com/ElectronBreach/opencode-unlimited-usage/macos"

say(){ echo -e "  $*"; }

# launchctl bootout is asynchronous: bootstrapping the same label 100ms later
# can fail on a still-tearing-down service, and the legacy `load -w` fallback
# "succeeds" in a compatibility mode launchd then reaps seconds later — which
# looks exactly like a healthy agent that vanishes after install. wait for the
# domain to actually release the label, then bootstrap with retries, then
# verify twice with a delay.
bootout_wait(){
  local domain="$1" label="$2" i
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  for i in $(seq 1 40); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
  return 0
}

bootstrap_verified(){
  local domain="$1" plist="$2" label="$3" i
  for i in 1 2 3 4 5; do
    launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
    sleep 1
    launchctl print "$domain/$label" >/dev/null 2>&1 || { sleep 1; continue; }
    sleep 2          # survive the reaping window before trusting it
    launchctl print "$domain/$label" >/dev/null 2>&1 && return 0
  done
  return 1
}
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
die(){ bad "$*"; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
[ -n "$SRC" ] && [ -d "$SRC/scripts" ] || SRC=""   # piped-from-curl: fetch from github

echo ""
echo "  ================================="
echo "  Opencode Unlimited Usage (macOS)"
echo "  ================================="
echo ""

# ---------------------------------------------------------------- platform
[ "$(uname -s)" = "Darwin" ] || die "this build is macOS only — use the linux build on linux"
[ "$(id -u)" = 0 ] && die "run me as your normal user, not root"
command -v launchctl >/dev/null 2>&1 || die "launchd not found — is this really macOS?"
command -v python3   >/dev/null 2>&1 || die "python3 required (xcode-select --install)"
command -v curl      >/dev/null 2>&1 || die "curl required"

# ---------------------------------------------------------------- sudo
# order: cached (sudo -n) → password prompt from your terminal (curl | bash
# has no usable stdin — rustup and homebrew solve it the same way) →
# stdin fallback for people who download the script first.
if ! sudo -n true 2>/dev/null; then
  if [ -n "${SUDO_ASKPASS:-}" ] && sudo -A -v 2>/dev/null; then
    ok "sudo authenticated (askpass)"
  elif bash -c 'sudo -v </dev/tty' 2>/dev/null; then
    ok "sudo authenticated"
  elif [ ! -t 0 ]; then
    sudo -S -v >/dev/null 2>&1 || die "sudo failed — password came wrong from stdin"
    ok "sudo authenticated (from stdin)"
  else
    die "sudo failed — run me from a real terminal"
  fi
fi
# sudo that works from a terminal, an askpass helper, or piped stdin
s(){
  if sudo -n true 2>/dev/null; then sudo "$@"
  elif [ -n "${SUDO_ASKPASS:-}" ] && sudo -A true 2>/dev/null; then sudo -A "$@"
  elif [ -t 0 ]; then sudo "$@"
  else sudo -S "$@"
  fi
}

# keep the sudo timestamp alive for the whole install
( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
SUDO_KEEP=$!
trap 'kill $SUDO_KEEP 2>/dev/null' EXIT

# ---------------------------------------------------------------- opencode CLI
# resolve the REAL binary, never a shim from a previous install (a copied shim
# that re-enters a lane is an infinite loop, not a binary).
resolve_real_opencode(){
  local c
  for c in "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode "$HOME/.npm-global/bin/opencode"; do
    [ -x "$c" ] || continue
    grep -qI "zen-lane\|scripts/lane.sh" "$c" 2>/dev/null && continue
    printf '%s' "$c"; return 0
  done
  if command -v opencode >/dev/null 2>&1; then
    c="$(command -v opencode)"
    grep -qI "zen-lane\|scripts/lane.sh" "$c" 2>/dev/null || { printf '%s' "$c"; return 0; }
  fi
  return 1
}

OC_REAL="$(resolve_real_opencode)" || OC_REAL=""
if [ -z "$OC_REAL" ]; then
  say "opencode CLI not found — installing (official installer)"
  if curl -fsSL https://opencode.ai/install 2>/dev/null | bash >/dev/null 2>&1; then
    OC_REAL="$(resolve_real_opencode)" || OC_REAL=""
  fi
  [ -n "$OC_REAL" ] || die "opencode install failed — do it yourself: https://opencode.ai/install"
  ok "opencode installed"
else
  ok "opencode found: $OC_REAL"
fi

# ---------------------------------------------------------------- warp-cli
WARP=""
if command -v warp-cli >/dev/null 2>&1; then
  WARP="$(command -v warp-cli)"
fi
# reject a 0-byte stub (this is what broke the previous install)
if [ -n "$WARP" ] && [ ! -s "$WARP" ]; then
  warn "found 0-byte stub at $WARP — removing"
  s rm -f "$WARP"
  WARP=""
fi
if [ -z "$WARP" ]; then
  command -v brew >/dev/null 2>&1 || die "homebrew required for the warp cask — https://brew.sh"
  say "warp-cli not found — installing cloudflare warp (brew cask)"
  brew install --cask cloudflare-warp >/dev/null 2>&1 \
    || SUDO_ASKPASS=/bin/false brew install --cask cloudflare-warp >/dev/null 2>&1 \
    || die "warp cask install failed — brew install --cask cloudflare-warp"
  command -v warp-cli >/dev/null 2>&1 && WARP="$(command -v warp-cli)"
  [ -n "$WARP" ] && [ -s "$WARP" ] || die "warp-cli install failed — see https://cloudflarewarp.com"
  ok "cloudflare warp installed"
else
  ok "warp-cli found: $WARP"
fi

# warp-cli callers: some boxes wrap warp-cli with a shim that already passes
# --accept-tos, and passing it twice makes the CLI die. so: try with the
# flag first (fresh installs need it), fall back to without (shimmed boxes).
w(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -A "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -A "$WARP" "$@" >/dev/null 2>&1; }
wo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -A "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -A "$WARP" "$@" 2>/dev/null; }

# ---------------------------------------------------------------- scripts
mkdir -p "$DEST/scripts" "$HOME/.local/bin" "$GUARD_DIR"
if [ -n "$SRC" ]; then
  cp "$SRC/scripts/"*.sh "$DEST/scripts/"
  [ -f "$SRC/AGENTS.md" ] && cp "$SRC/AGENTS.md" "$DEST/AGENTS.md"
else
  say "fetching scripts from github"
  for f in warp-keeper.sh zen-lane.sh zen-guard.sh zen-hop.sh doctor.sh audit.sh; do
    curl -fsSL "$RAW/scripts/$f" -o "$DEST/scripts/$f" || die "could not fetch $f"
  done
  curl -fsSL "$RAW/AGENTS.md" -o "$DEST/AGENTS.md" 2>/dev/null || true
  # the branch must actually be the macOS one, not linux scripts from main
  grep -q "launchctl" "$DEST/scripts/warp-keeper.sh" \
    || grep -q "launchd" "$DEST/scripts/warp-keeper.sh" \
    || die "fetched linux scripts from $RAW — this installer needs the macos branch"
fi
chmod +x "$DEST/scripts/"*.sh

# scripts pick the warp binary themselves (OUC_WARP_BIN env if the service
# provides one, else standard paths). no baking — sed-editing scripts after
# download is how you ship a broken script.
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/scripts/zen-hop.sh" "$HOME/.local/bin/${BRAND}-hop"
ln -sf "$DEST/scripts/doctor.sh"  "$HOME/.local/bin/${BRAND}-doctor"

# second home: ~/.opencode/bin is already first on PATH in a typical opencode
# shell, and it exists even when an older terminal was started before
# ~/.local/bin was added to PATH. linking here means the commands resolve in
# terminals that are already open, not only in new ones.
if [ -d "$HOME/.opencode/bin" ]; then
  ln -sf "$DEST/scripts/zen-hop.sh" "$HOME/.opencode/bin/${BRAND}-hop"
  ln -sf "$DEST/scripts/doctor.sh"  "$HOME/.opencode/bin/${BRAND}-doctor"
fi
ok "scripts in $DEST"

# ---------------------------------------------------------------- DNS baseline
# captured before we touch the tunnel, restored by the keeper if DNS breaks
# while the tunnel is down. this is the guard against the old lockout.
: > "$GUARD_DIR/dns-baseline.txt"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r svc; do
  case "$svc" in
    \**) continue ;;
  esac
  raw=$(networksetup -getdnsservers "$svc" 2>/dev/null)
  case "$raw" in
    *"There aren't any DNS Servers"*) servers="Empty" ;;
    *) servers=$(printf '%s' "$raw" | tr '\n' ' ' | sed 's/ *$//') ;;
  esac
  printf '%s\t%s\n' "$svc" "$servers" >> "$GUARD_DIR/dns-baseline.txt"
done
ok "dns baseline captured"

# ---------------------------------------------------------------- sudoers (warp-cli for the unattended guard/hop, pf read+flush
# for the doctor and the fail-open path, and the marked hosts pin for the
# lane). every entry is exact-args — sudoers will not accept anything else.
SUDOERS_NEED="$USER ALL=(root) NOPASSWD: $WARP, /sbin/pfctl -a OUC_LEAKGUARD -s rules, /sbin/pfctl -a OUC_LEAKGUARD -F all, /bin/cp /tmp/ouc-hosts.* /etc/hosts"
SUDOERS_NOW="$(sudo -n cat "$SUDOERS_FILE" 2>/dev/null || echo '')"
if [ "$SUDOERS_NOW" != "$SUDOERS_NEED" ]; then
  say "sudoers: passwordless warp-cli + pf read/flush + hosts pin"
  printf '%s\n' "$SUDOERS_NEED" | s tee "$SUDOERS_FILE" >/dev/null
  s chmod 440 "$SUDOERS_FILE"
  s visudo -c >/dev/null 2>&1 || { s rm -f "$SUDOERS_FILE"; die "sudoers rejected — this should never happen"; }
fi
wo status >/dev/null 2>&1 || die "passwordless warp-cli did not work — check $SUDOERS_FILE"
ok "passwordless warp-cli works"

# ---------------------------------------------------------------- warp: register + connect (with a DNS leash)
say "registering warp + tunnel up"
w registration new >/dev/null 2>&1   # already-registered boxes just error, fine
# tunnel_only: traffic rides WARP, DNS stays on the system resolver. DoH /
# warp+doh is what left this Mac with a resolver it could not reach once the
# tunnel dropped. override with OUC_WARP_MODE=warp if you want WARP's DNS.
w mode "${OUC_WARP_MODE:-tunnel_only}" >/dev/null 2>&1 || true
w connect >/dev/null 2>&1

CONNECTED=0
for i in $(seq 1 10); do
  sleep 3
  wo status | head -1 | grep -q Connected && { CONNECTED=1; break; }
done

restore_dns_baseline(){
  local svc servers restored=0
  if [ -f "$GUARD_DIR/dns-baseline.txt" ]; then
    while IFS=$'\t' read -r svc servers; do
      [ -n "$svc" ] || continue
      networksetup -listallnetworkservices 2>/dev/null | grep -qx "$svc" || continue
      if [ -z "$servers" ] || [ "$servers" = "Empty" ]; then
        networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1 && restored=1
      else
        # shellcheck disable=SC2086
        networksetup -setdnsservers "$svc" $servers >/dev/null 2>&1 && restored=1
      fi
    done < "$GUARD_DIR/dns-baseline.txt"
  fi
  if [ "$restored" = 0 ]; then
    networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8 >/dev/null 2>&1 || true
  fi
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

if [ "$CONNECTED" = 1 ]; then
  ok "warp tunnel: connected"
  # DNS leash: if WARP took the resolver and cannot serve it, fall back
  sleep 2
  if ! dig +short +time=3 +tries=1 opencode.ai >/dev/null 2>&1 || [ -z "$(dig +short +time=3 +tries=1 opencode.ai 2>/dev/null)" ]; then
    warn "dns broken after connect — restoring baseline"
    restore_dns_baseline
    sleep 2
    if ! dig +short +time=3 +tries=1 opencode.ai >/dev/null 2>&1 || [ -z "$(dig +short +time=3 +tries=1 opencode.ai 2>/dev/null)" ]; then
      warn "dns still broken — disconnecting warp (direct egress, no lockout)"
      w disconnect >/dev/null 2>&1 || true
      restore_dns_baseline
      CONNECTED=0
    fi
  fi
else
  warn "warp not up yet — nothing is armed, the keeper will keep retrying"
fi

# ---------------------------------------------------------------- keeper (root LaunchDaemon)
cat > /tmp/ouc-keeper.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$DAEMON_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/scripts/warp-keeper.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OUC_HOME</key><string>$DEST</string>
    <key>OUC_WARP_BIN</key><string>$WARP</string>
    <key>OUC_LEAKGUARD</key><string>${OUC_LEAKGUARD:-0}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>20</integer>
  <key>StandardOutPath</key><string>$GUARD_DIR/keeper-daemon.log</string>
  <key>StandardErrorPath</key><string>$GUARD_DIR/keeper-daemon.log</string>
</dict>
</plist>
EOF
s install -m 644 -o root -g wheel /tmp/ouc-keeper.plist "$DAEMON_PLIST" || die "could not install keeper plist"
rm -f /tmp/ouc-keeper.plist
s launchctl bootout system/"$DAEMON_LABEL" >/dev/null 2>&1 || true
for i in $(seq 1 40); do
  s launchctl print system/"$DAEMON_LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
DAEMON_OK=0
for i in 1 2 3 4 5; do
  s launchctl bootstrap system "$DAEMON_PLIST" >/dev/null 2>&1 || true
  sleep 1
  if s launchctl print system/"$DAEMON_LABEL" >/dev/null 2>&1; then
    sleep 2
    s launchctl print system/"$DAEMON_LABEL" >/dev/null 2>&1 && { DAEMON_OK=1; break; }
  fi
done
[ "$DAEMON_OK" = "1" ] \
  && ok "keeper daemon (root): running" \
  || die "keeper did not start — check: sudo launchctl print system/$DAEMON_LABEL"

# ---------------------------------------------------------------- guard (user LaunchAgent)
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/scripts/zen-guard.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OUC_WARP_BIN</key><string>$WARP</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$GUARD_DIR/guard-daemon.log</string>
  <key>StandardErrorPath</key><string>$GUARD_DIR/guard-daemon.log</string>
</dict>
</plist>
EOF
plutil -lint "$AGENT_PLIST" >/dev/null 2>&1 || die "guard plist invalid"
bootout_wait "gui/$(id -u)" "$AGENT_LABEL"
bootstrap_verified "gui/$(id -u)" "$AGENT_PLIST" "$AGENT_LABEL" \
  && ok "zen-guard agent (user): running" \
  || die "guard did not start — check: launchctl print gui/$(id -u)/$AGENT_LABEL"

# ---------------------------------------------------------------- TUI shim (the lane + credit enforcement)
if [ "$OC_REAL" = "$SHIM" ]; then
  OC_REAL="$(resolve_real_opencode)" || OC_REAL=""
  [ -n "$OC_REAL" ] || die "could not resolve the real opencode binary (a shim was found in its place)"
fi
printf '#!/usr/bin/env bash\nexport OUC_REAL_BIN="%s"\nexec bash "%s/scripts/zen-lane.sh" "$@"\n' "$OC_REAL" "$DEST" > "$SHIM"
chmod +x "$SHIM"
ok "opencode entry → lane (fresh edge per launch)"

# ---------------------------------------------------------------- verify end to end (the installer doesn't lie)
say "verifying the lane end to end…"
IP=$(curl -4 -s -m 12 https://api64.ipify.org 2>/dev/null)
case "$IP" in
  104.28.*|162.159.*|172.64.*|188.114.*|2a09:*|2606:*) ok "egress is cloudflare warp: $IP" ;;
  "") bad "no egress — keeper is still setting up; run ${BRAND}-doctor in a minute" ;;
  *)  warn "egress is not warp yet ($IP) — keeper still setting up, re-check in a minute" ;;
esac

if dig +short +time=3 +tries=1 opencode.ai >/dev/null 2>&1 && [ -n "$(dig +short +time=3 +tries=1 opencode.ai 2>/dev/null)" ]; then
  ok "dns: opencode.ai resolves"
else
  warn "dns: opencode.ai not resolving yet — keeper restores the baseline if it stays broken"
  dscacheutil -flushcache >/dev/null 2>&1 || true
fi

if [ -f "$HOME/.opencode/AGENTS.md" ] && grep -q "ElectronCursed" "$HOME/.opencode/AGENTS.md"; then
  ok "credit file active (every AI response signs off)"
else
  say "credit file lands on first opencode launch (lane enforces it)"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "PATH has ~/.local/bin" ;;
  *) say "add this to your ~/.zshrc, then reopen the terminal:"
     say "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo ""
ok "DONE. close & reopen your terminal, then just run:  opencode"
say "first launch: opencode sets up its device identity — if it asks to login, do it once (free)"
echo ""
say "wall hits while you work? zen-guard rotates in ~15s — just re-send your message."
say "health check any time:  ${BRAND}-doctor   ·   fresh identity now:  ${BRAND}-hop"
if [ "${OUC_LEAKGUARD:-0}" = "1" ]; then
  say "leak guard: ENABLED (opt-in) — fail-open, flushes on any dns/egress loss"
else
  say "leak guard: OFF (default) — WARP tunnel + rotation only, zero pf risk"
  say "enable later with: OUC_LEAKGUARD=1 ./install.sh"
fi
echo ""
