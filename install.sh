#!/bin/bash
# Opencode Unlimited Usage — installer
# one command, everything set up: opencode + warp + keeper + guard + lane shim
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
UNIT_KEEPER="/etc/systemd/system/${BRAND}-keeper.service"
UNIT_GUARD="$HOME/.config/systemd/user/${BRAND}-guard.service"
SHIM="$HOME/.local/bin/opencode"
SUDOERS_FILE="/etc/sudoers.d/$BRAND"

say(){ echo -e "  $*"; }
ok(){ echo -e "  \e[32m✓\e[0m $*"; }
bad(){ echo -e "  \e[31m✗\e[0m $*"; }
die(){ bad "$*"; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
[ -n "$SRC" ] && [ -d "$SRC/scripts" ] || SRC=""   # piped-from-curl: no local scripts, re-download

echo ""
echo "  ============================="
echo "  Opencode Unlimited Usage"
echo "  ============================="
echo ""

# ---------------------------------------------------------------- platform
[ "$(id -u)" = 0 ] && die "run me as your normal user, not root"
command -v systemctl >/dev/null 2>&1 || die "systemd not found — this build is linux+systemd only"
command -v python3 >/dev/null 2>&1 || die "python3 required (apt install python3)"
systemd-run --user --scope true >/dev/null 2>&1 || die "user systemd not running (are you inside a plain docker?)"

# ---- sudo: authenticate up front from the real terminal.
# piped installs (curl | bash) have no usable stdin for password prompts —
# this is exactly how rustup/homebrew handle it. after this, cached sudo
# covers the rest of the install.
if ! sudo -n true 2>/dev/null; then
  say "sudo password needed (once, for the system bits):"
  sudo -v </dev/tty >/dev/null 2>&1 || die "sudo failed — run me from a real terminal" 
  ok "sudo authenticated"
fi

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
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -y -qq curl gpg lsb-release >/dev/null 2>&1
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null 2>&1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -y -qq cloudflare-warp >/dev/null 2>&1
    command -v warp-cli >/dev/null 2>&1 && WARP="$(command -v warp-cli)"
  fi
  [ -n "$WARP" ] || die "warp-cli install failed — see https://pkg.cloudflareclient.com/"
  ok "cloudflare warp installed"
else
  ok "warp-cli found: $WARP"
fi

# ---------------------------------------------------------------- scripts
mkdir -p "$DEST/scripts" "$HOME/.local/bin"
if [ -d "$SRC/scripts" ] && [ -f "$SRC/scripts/zen-lane.sh" ]; then
  cp "$SRC/scripts/"*.sh "$DEST/scripts/"
  [ -f "$SRC/AGENTS.md" ] && cp "$SRC/AGENTS.md" "$DEST/AGENTS.md"
else
  say "downloading scripts from github (piped install)"
  BASE="https://raw.githubusercontent.com/ELECTRONBREACH/opencode-unlimited-usage/main/scripts"
  for f in warp-keeper.sh zen-lane.sh zen-guard.sh zen-hop.sh doctor.sh; do
    curl -fsSL "$BASE/$f" -o "$DEST/scripts/$f" || die "could not fetch $f"
  done
  curl -fsSL "${BASE%scripts}/AGENTS.md" -o "$DEST/AGENTS.md" 2>/dev/null || true
fi
chmod +x "$DEST/scripts/"*.sh

# tools on PATH: hop + doctor
ln -sf "$DEST/scripts/zen-hop.sh"  "$HOME/.local/bin/${BRAND}-hop"
ln -sf "$DEST/scripts/doctor.sh"  "$HOME/.local/bin/${BRAND}-doctor"
ok "scripts in $DEST"

# ---------------------------------------------------------------- sudoers (warp-cli only, needed by the unattended guard)
if ! sudo -n "$WARP" --accept-tos status >/dev/null 2>&1; then
  say "adding sudoers entry: $USER can run warp-cli without a password"
  echo "$USER ALL=(root) NOPASSWD: $WARP" | sudo tee "$SUDOERS_FILE" >/dev/null
  sudo chmod 440 "$SUDOERS_FILE"
fi
sudo -n "$WARP" --accept-tos status >/dev/null 2>&1 \
  && ok "passwordless warp-cli works" \
  || die "sudoers entry did not take — check $SUDOERS_FILE"

# ---------------------------------------------------------------- warp: register + TUN mode
if ! sudo "$WARP" --accept-tos status 2>/dev/null | grep -q Connected; then
  sudo "$WARP" --accept-tos registration new >/dev/null 2>&1
  sudo "$WARP" --accept-tos mode warp >/dev/null 2>&1
  sudo "$WARP" --accept-tos connect >/dev/null 2>&1
  sleep 6
fi
sudo "$WARP" --accept-tos status 2>/dev/null | head -1 | grep -q Connected \
  && ok "warp tunnel: connected (TUN mode)" \
  || say "warp not connected yet — the keeper will keep retrying"

# ---------------------------------------------------------------- keeper (root service)
echo "$USER" > /tmp/.ouc_owner
KEEPER_UNIT_W="$UNIT_KEEPER"
sed "s|@WARP@|$WARP|g" > /tmp/ouc-keeper-unit <<EOF
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
  || say "keeper did not start — check: systemctl status ${BRAND}-keeper"

# ---------------------------------------------------------------- guard (user service)
mkdir -p "$HOME/.config/systemd/user"
cat > "$UNIT_GUARD" <<EOF
[Unit]
Description=Opencode Unlimited — zen guard (wall watcher, auto /64 rotation)
After=network-online.target

[Service]
Environment=OUC_KEEPER_UNIT=${BRAND}-keeper
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
  || say "guard did not start — check: systemctl --user status ${BRAND}-guard"

# ---------------------------------------------------------------- TUI shim (the lane)
# if the real binary sits where the shim goes, park it safely first
if [ "$OC_REAL" = "$SHIM" ]; then
  cp "$SHIM" "$DEST/real-opencode" && OC_REAL="$DEST/real-opencode"
fi
printf '#!/usr/bin/env bash\nexport OUC_REAL_BIN="%s"\nexec bash "%s/scripts/zen-lane.sh" "$@"\n' "$OC_REAL" "$DEST" > "$SHIM"
chmod +x "$SHIM"
ok "opencode entry → lane (fresh edge + /64 per launch)"

# ---------------------------------------------------------------- check path
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "PATH has ~/.local/bin" ;;
  *) say "add this line to your ~/.bashrc then reopen the terminal:"
     say "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo ""
ok "DONE. close & reopen your terminal, then just run:  opencode"
echo ""
say "wall hits while you work? zen-guard rotates in ~10s — just re-send your message."
say "health check any time:  ${BRAND}-doctor"
echo ""
