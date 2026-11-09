# Makefile — one place for every repeatable action.
#
#   make check     payload is current + every script parses
#   make build     compile the HUD
#   make test      doctor + audit against the live install
#   make install   install (or reinstall) on this machine
#   make release   dist/opencode-unlimited-mac-<version>.tar.gz + SHA256SUMS
#   make clean     remove dist/
#
# `install` and `test` touch the machine. everything else is read-only.

SHELL   := /bin/bash
VERSION := $(shell cat VERSION)
NAME    := opencode-unlimited-mac
DIST    := dist
BUNDLE  := $(DIST)/$(NAME)-$(VERSION)
SCRIPTS := $(wildcard scripts/*.sh) scripts/overlay/main.swift scripts/overlay/overlay.html

.PHONY: all check build test install release clean fmt

all: check

check:
	@bash -n install.sh && bash -n uninstall.sh
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done
	@echo "syntax: ok"
	@bash tools/embed.sh --check

build:
	@bash scripts/overlay/build.sh

test: check
	@bash scripts/doctor.sh 2>&1 | tail -20
	@echo
	@bash scripts/audit.sh 2>&1 | tail -4

install:
	@bash tools/embed.sh
	@./install.sh

release: check
	@rm -rf "$(BUNDLE)" && mkdir -p "$(BUNDLE)"
	@cp install.sh uninstall.sh README.md LICENSE VERSION AGENTS.md "$(BUNDLE)/"
	@mkdir -p "$(BUNDLE)/scripts/overlay" "$(BUNDLE)/docs" "$(BUNDLE)/tools"
	@cp scripts/*.sh "$(BUNDLE)/scripts/"
	@cp scripts/overlay/main.swift scripts/overlay/overlay.html \
	    scripts/overlay/build.sh "$(BUNDLE)/scripts/overlay/"
	@cp docs/*.md "$(BUNDLE)/docs/"
	@cp tools/embed.sh "$(BUNDLE)/tools/"
	@cd "$(DIST)" && tar -czf "$(NAME)-$(VERSION).tar.gz" "$(NAME)-$(VERSION)"
	@cd "$(DIST)" && shasum -a 256 "$(NAME)-$(VERSION).tar.gz" > SHA256SUMS
	@echo "release: $(DIST)/$(NAME)-$(VERSION).tar.gz"
	@cat "$(DIST)/SHA256SUMS"

clean:
	@rm -rf "$(DIST)"
	@echo "dist/ removed"
