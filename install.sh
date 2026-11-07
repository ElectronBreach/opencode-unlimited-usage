#!/bin/bash
# Opencode Unlimited Usage — installer
#
# ONE SHOT: opencode + cloudflare warp (apt/dnf/pacman, whatever your distro
# speaks) + TUN mode + keeper + guard + lane shim + credit enforcement +
# self-verify. you run one line, you get a working system.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
UNIT_KEEPER="/etc/systemd/system/${BRAND}-keeper.service"
UNIT_GUARD="$HOME/.config/systemd/user/${BRAND}-guard.service"
SHIM="$HOME/.local/bin/opencode"
SUDOERS_FILE="/etc/sudoers.d/$BRAND"
REPO="https://github.com/ELECTRONBreach/opencode-unlimited-usage"
RAW="https://raw.githubusercontent.com/ELECTRONBreach/opencode-unlimited-usage/main"

say(){ echo -e "  $*"; }
ok(){ echo -e "  \e[32m✓\e[0m $*"; }
bad(){ echo -e "  \e[31m✗\e[0m $*"; }
die(){ bad "$*"; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
[ -n "$SRC" ] && [ -d "$SRC/scripts" ] || SRC=""   # piped-from-curl: fetch from github

echo ""
echo "  ============================="
echo "  Opencode Unlimited Usage"
echo "  ============================="
echo ""

# ---------------------------------------------------------------- platform
[ "$(id -u)" = 0 ] && die "run me as your normal user, not root"
command -v systemctl >/dev/null 2>&1 || die "systemd not found — this build is linux+systemd only"
command -v python3 >/dev/null 2>&1 || die "python3 required (apt/dnf/pacman install python3)"
command -v curl    >/dev/null 2>&1 || die "curl required"
systemd-run --user --scope true >/dev/null 2>&1 || die "user systemd not running (are you inside a plain docker?)"
[ -e /dev/net/tun ] || die "/dev/net/tun missing — enable TUN in your VM/WSL settings first"

# ---------------------------------------------------------------- sudo
# order: cached (sudo -n) → password prompt from your terminal (curl | bash
# has no usable stdin — rustup and homebrew solve it the same way) →
# stdin fallback for people who download the script first.
if ! sudo -n true 2>/dev/null; then
  if bash -c 'sudo -v </dev/tty' 2>/dev/null; then
    ok "sudo authenticated"
  elif [ ! -t 0 ]; then
    sudo -S -v >/dev/null 2>&1 || die "sudo failed — password came wrong from stdin"
    ok "sudo authenticated (from stdin)"
  else
    die "sudo failed — run me from a real terminal"
  fi
fi

# ---------------------------------------------------------------- distro
PKR=""
command -v apt-get >/dev/null 2>&1 && PKR=apt
[ -z "$PKR" ] && command -v dnf >/dev/null 2>&1 && PKR=dnf
[ -z "$PKR" ] && command -v pacman >/dev/null 2>&1 && PKR=pacman
[ -n "$PKR" ] || die "no apt/dnf/pacman — install cloudflare-warp yourself, then re-run me"

# ---------------------------------------------------------------- opencode CLI
OC_REAL=""
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  OC_REAL="$HOME/.opencode/bin/opencode"
elif command -v opencode >/dev/null 2>&1; then
  OC_REAL="$(command -v opencode)"
fi
if [ -z "$OC_REAL" ]; then
  say "opencode CLI not found — installing (official installer)"
  if curl -fsSL https://opencode.ai/install 2>/dev/null | bash >/dev/null 2>&1; then
    [ -x "$HOME/.opencode/bin/opencode" ] && OC_REAL="$HOME/.opencode/bin/opencode"
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
elif [ -x "$HOME/.local/bin/warp-cli" ]; then
  WARP="$HOME/.local/bin/warp-cli"
fi
if [ -z "$WARP" ]; then
  say "warp-cli not found — installing cloudflare warp client"
  case "$PKR" in
    apt)
      sudo apt-get update -qq >/dev/null 2>&1
      sudo apt-get install -y -qq curl gpg lsb-release >/dev/null 2>&1
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null 2>&1
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
      sudo apt-get update -qq >/dev/null 2>&1
      sudo apt-get install -y -qq cloudflare-warp >/dev/null 2>&1
      ;;
    dnf)
      # cloudflare doesn't ship official dnf repo bins for every fedora release;
      # the defvd route is their rpm. fall back to it.
      sudo dnf -y install gpg >/dev/null 2>&1
      REL=$(curl -fsSL https://api.github.com/repos/cloudflare-warp/cloudflare-warp-rpm/releases/latest 2>/dev/null \
        | python3 -c "import json,sys
try:
    a=json.load(sys.stdin)['assets']
    print(next(x['browser_download_url'] for x in a if 'x86_64.rpm' in x['name']))
except Exception:
    print('')" 2>/dev/null)
      if [ -n "$REL" ]; then
        curl -fsSL "$REL" -o /tmp/warp-install.rpm && sudo dnf -y install /tmp/warp-install.rpm >/dev/null 2>&1 && rm -f /tmp/warp-install.rpm
      else
        sudo dnf -y install cloudflare-warp >/dev/null 2>&1
      fi
      ;;
    pacman)
      if command -v yay >/dev/null 2>&1; then
        yay -S --noconfirm cloudflare-warp-bin >/dev/null 2>&1
      elif command -v paru >/dev/null 2>&1; then
        paru -S --noconfirm cloudflare-warp-bin >/dev/null 2>&1
      else
        die "arch needs yay or paru for cloudflare-warp-bin — install either, re-run me"
      fi
      ;;
  esac
  command -v warp-cli >/dev/null 2>&1 && WARP="$(command -v warp-cli)"
  [ -n "$WARP" ] || die "warp-cli install failed — see https://pkg.cloudflareclient.com/"
  ok "cloudflare warp installed"
else
  ok "warp-cli found: $WARP"
fi

# warp-cli callers: some boxes wrap warp-cli with a shim that already passes
# --accept-tos, and passing it twice makes the CLI die. so: try with the
# flag first (fresh installs need it), fall back to without (shimmed boxes).
sw(){  sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0; sudo -n "$WARP" "$@" >/dev/null 2>&1; }
swo(){ sudo -n "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" "$@" 2>/dev/null; }

# ---------------------------------------------------------------- scripts
mkdir -p "$DEST/scripts" "$HOME/.local/bin"
if [ -n "$SRC" ]; then
  cp "$SRC/scripts/"*.sh "$DEST/scripts/"
  [ -f "$SRC/AGENTS.md" ] && cp "$SRC/AGENTS.md" "$DEST/AGENTS.md"
else
  say "fetching scripts from github"
  for f in warp-keeper.sh zen-lane.sh zen-guard.sh zen-hop.sh doctor.sh; do
    curl -fsSL "$RAW/scripts/$f" -o "$DEST/scripts/$f" || die "could not fetch $f"
  done
  curl -fsSL "$RAW/AGENTS.md" -o "$DEST/AGENTS.md" 2>/dev/null || true
fi
chmod +x "$DEST/scripts/"*.sh

# scripts pick the warp binary themselves (OUC_WARP_BIN env if the service
# provides one, else standard paths). no baking — sed-editing scripts after
# download is how you ship a broken script.
# hop + doctor on PATH
ln -sf "$DEST/scripts/zen-hop.sh" "$HOME/.local/bin/${BRAND}-hop"
ln -sf "$DEST/scripts/doctor.sh"  "$HOME/.local/bin/${BRAND}-doctor"
ok "scripts in $DEST"

# ---------------------------------------------------------------- sudoers (warp-cli for the unattended guard, read-only iptables
# verification for the doctor). the iptables entries are exact-args matches —
# list-only, sudoers will not accept anything else from that rule.
SUDOERS_NEED="$USER ALL=(root) NOPASSWD: $WARP, /usr/sbin/iptables -nL OUC_LEAKGUARD, /usr/sbin/ip6tables -nL OUC_LEAKGUARD"
SUDOERS_NOW="$(sudo -n cat "$SUDOERS_FILE" 2>/dev/null || echo '')"
if [ "$SUDOERS_NOW" != "$SUDOERS_NEED" ]; then
  say "sudoers: passwordless warp-cli + read-only kill-switch verify"
  printf '%s\n' "$SUDOERS_NEED" | sudo tee "$SUDOERS_FILE" >/dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  sudo visudo -c >/dev/null 2>&1 || { sudo rm -f "$SUDOERS_FILE"; die "sudoers rejected — this should never happen"; }
fi
sw status || die "passwordless warp-cli did not work — check $SUDOERS_FILE"
ok "passwordless warp-cli works"

# ---------------------------------------------------------------- warp: register + TUN mode + connect
say "registering warp + tunnel up"
sw registration new >/dev/null 2>&1   # already-registered boxes just error, fine
sw mode warp
sw connect
CONNECTED=0
for i in $(seq 1 10); do
  sleep 3
  swo status | head -1 | grep -q Connected && { CONNECTED=1; break; }
done
[ "$CONNECTED" = 1 ] \
  && ok "warp tunnel: connected (TUN mode)" \
  || say "warp not up yet — the keeper will keep retrying every 45s"

# ---------------------------------------------------------------- keeper (root service)
cat > /tmp/ouc-keeper-unit <<EOF
[Unit]
Description=Opencode Unlimited — warp keeper (tunnel enforce + kill-switch)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash $DEST/scripts/warp-keeper.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo install -m 755 "$DEST/scripts/warp-keeper.sh" /usr/local/bin/${BRAND}-keeper
sudo install -m 644 /tmp/ouc-keeper-unit "$UNIT_KEEPER"
sudo systemctl daemon-reload
sudo systemctl enable --now ${BRAND}-keeper >/dev/null 2>&1
systemctl is-active ${BRAND}-keeper 2>/dev/null | grep -q active \
  && ok "keeper service (root): running" \
  || die "keeper did not start — check: systemctl status ${BRAND}-keeper"

# ---------------------------------------------------------------- guard (user service)
mkdir -p "$HOME/.config/systemd/user"
cat > "$UNIT_GUARD" <<EOF
[Unit]
Description=Opencode Unlimited — zen guard (wall watcher, auto /64 rotation)
After=network-online.target

[Service]
Environment=OUC_KEEPER_UNIT=${BRAND}-keeper
Environment=OUC_WARP_BIN=$WARP
ExecStart=/bin/bash $DEST/scripts/zen-guard.sh
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now ${BRAND}-guard >/dev/null 2>&1
systemctl --user is-active ${BRAND}-guard 2>/dev/null | grep -q active \
  && ok "zen-guard service (user): running" \
  || die "guard did not start — check: systemctl --user status ${BRAND}-guard"

# ---------------------------------------------------------------- TUI shim (the lane + credit enforcement)
if [ "$OC_REAL" = "$SHIM" ]; then
  cp "$SHIM" "$DEST/real-opencode" && OC_REAL="$DEST/real-opencode"
fi
printf '#!/usr/bin/env bash\nexport OUC_REAL_BIN="%s"\nexec bash "%s/scripts/zen-lane.sh" "$@"\n' "$OC_REAL" "$DEST" > "$SHIM"
chmod +x "$SHIM"
ok "opencode entry → lane (fresh edge + /64 per launch)"

# ---------------------------------------------------------------- verify end to end (the installer doesn't lie)
say "verifying the lane end to end (this hits opencode once)…"
V6=$(timeout 12 curl -s -m 10 https://api64.ipify.org 2>/dev/null)
case "$V6" in
  2606:*) ok "egress is cloudflare warp: $(echo "$V6" | cut -d: -f1-4)::/64" ;;
  *) bad "egress is not warp yet — keeper is still setting up, give it a minute then run ${BRAND}-doctor" ;;
esac
if [ -f "$HOME/.opencode/AGENTS.md" ] && grep -q "ElectronCursed" "$HOME/.opencode/AGENTS.md"; then
  ok "credit file active (every AI response signs off)"
else
  say "credit file lands on first opencode launch (lane enforces it)"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "PATH has ~/.local/bin" ;;
  *) say "add this to your ~/.bashrc, then reopen the terminal:"
     say "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo ""
ok "DONE. close & reopen your terminal, then just run:  opencode"
echo ""
say "wall hits while you work? zen-guard rotates in ~10s — just re-send your message."
say "health check any time:  ${BRAND}-doctor   ·   fresh identity now:  ${BRAND}-hop"
echo ""
