# opencode-unlimited
#
#   make mac            install on macOS (launchd) — reads mac/
#   make mac-uninstall  remove the agents and HUD
#   make linux          run the Linux installer (systemd)
#   make help           this list
#
# macOS has no systemd and no `unshare -rm`, so the root scripts cannot run
# there unchanged. `make mac` installs the macOS implementation instead: one
# launchd rotator, one root keeper, one HUD, one shared rotation lock, and
# unlimited rotation (no hourly cap).

SHELL := /bin/bash
UNAME := $(shell uname -s)

.PHONY: mac mac-uninstall linux linux-uninstall help check

help:
	@echo "opencode-unlimited"
	@echo ""
	@echo "  make mac            macOS install (launchd)  [$(UNAME)]"
	@echo "  make mac-uninstall  macOS uninstall"
	@echo "  make linux          Linux install (systemd)"
	@echo "  make linux-uninstall"
	@echo "  make check          syntax-check everything"

mac:
	@[ "$(UNAME)" = "Darwin" ] || { echo "make mac is for macOS; use 'make linux' (or WSL2)"; exit 1; }
	@bash mac/install-mac.sh

mac-uninstall:
	@bash mac/uninstall-mac.sh

linux:
	@[ "$(UNAME)" = "Linux" ] || echo "warning: not Linux — this installs systemd units"
	@bash install.sh

linux-uninstall:
	@bash uninstall.sh

check:
	@python3 -c "import ast,sys; ast.parse(open('mac/ocul.py').read()); print('mac/ocul.py ok')"
	@bash -n mac/install-mac.sh && echo "mac/install-mac.sh ok"
	@bash -n mac/uninstall-mac.sh && echo "mac/uninstall-mac.sh ok"
	@bash -n mac/ouctl && echo "mac/ouctl ok"
	@for f in mac/scripts/*.sh mac/overlay/build.sh; do bash -n "$$f" || exit 1; done && echo "mac/scripts/* ok"
	@for p in mac/plists/*.tmpl; do sed -e "s|__HOME__|$$HOME|g" -e "s|__WARP__|/usr/local/bin/warp-cli|g" -e "s|__PATH__|/usr/bin:/bin|g" "$$p" | plutil -lint - >/dev/null && echo "$$(basename $$p) ok"; done
