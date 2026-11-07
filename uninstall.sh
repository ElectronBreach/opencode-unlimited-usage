#!/bin/bash
# clean removal — services, firewall chain, sudoers entry, wrapper, credit
# file. your opencode data/sessions/auth are untouched.
set -u

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
WARP="$(command -v warp-cli || echo /usr/bin/warp-cli)"
[ -x "$WARP" ] || WARP="$HOME/.local/bin/warp-cli"

ok(){ echo -e "  \e[32m✓\e[0m $*"; }

echo ""
echo "  removing Opencode Unlimited Usage…"
echo ""

# stop services first
systemctl --user disable --now ${BRAND}-guard.service >/dev/null 2>&1 && ok "zen-guard stopped"
rm -f "$HOME/.config/systemd/user/${BRAND}-guard.service"
systemctl --user daemon-reload >/dev/null 2>&1

sudo systemctl disable --now ${BRAND}-keeper.service >/dev/null 2>&1 && ok "keeper stopped"
sudo rm -f "/etc/systemd/system/${BRAND}-keeper.service" "/usr/local/bin/${BRAND}-keeper"
sudo systemctl daemon-reload >/dev/null 2>&1

# firewall chains — allow traffic out normally again
sudo iptables  -D OUTPUT -j OUC_LEAKGUARD 2>/dev/null; sudo iptables  -F OUC_LEAKGUARD 2>/dev/null; sudo iptables  -X OUC_LEAKGUARD 2>/dev/null
sudo ip6tables -D OUTPUT -j OUC_LEAKGUARD 2>/dev/null; sudo ip6tables -F OUC_LEAKGUARD 2>/dev/null; sudo ip6tables -X OUC_LEAKGUARD 2>/dev/null
ok "kill-switch removed"

# sudoers entry
sudo rm -f "/etc/sudoers.d/$BRAND" && ok "sudoers entry removed"

# wrapper — restore direct access to the real binary if it still exists
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$HOME/.opencode/bin/opencode" > "$HOME/.local/bin/opencode"
  chmod +x "$HOME/.local/bin/opencode"
  ok "opencode entry → back to stock binary"
fi

# credit file (ours only — if the user added their own rules, those stay)
if [ -f "$HOME/.opencode/AGENTS.md" ] && grep -q "ElectronCursed" "$HOME/.opencode/AGENTS.md"; then
  rm -f "$HOME/.opencode/AGENTS.md"
  ok "credit file removed"
fi

# PATH tools
rm -f "$HOME/.local/bin/${BRAND}-hop" "$HOME/.local/bin/${BRAND}-doctor"

# the scripts + state. leave warp itself installed (it's a normal system
# package now) — disconnect the tunnel so traffic goes back to your real IP.
rm -rf "$DEST" && ok "scripts + guard state removed"
if command -v "$WARP" >/dev/null 2>&1; then
  sudo "$WARP" --accept-tos disconnect >/dev/null 2>&1 && ok "warp tunnel disconnected (package left installed)"
fi

echo ""
ok "gone. opencode itself + your sessions are untouched."
echo ""
