#!/bin/bash
# build the overlay .app bundle (idempotent; install.sh calls this too)
#
#   bash scripts/overlay/build.sh            → ~/Library/Application Support/opencode-unlimited/OpencodeOverlay.app
#   bash scripts/overlay/build.sh /tmp/out   → custom bundle path
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HOME/Library/Application Support/opencode-unlimited/OpencodeOverlay.app}"
BIN_NAME="opencode-unlimited-overlay"
SRC="$HERE/main.swift"
# one html, two layouts. live: scripts/overlay/build.sh + scripts/overlay.html.
# repo: mac/overlay/build.sh + mac/overlay/overlay.html. pick whichever exists
# instead of hard-coding a path that only works in one of them.
if [ -f "$HERE/overlay.html" ]; then
  HTML="$HERE/overlay.html"
else
  HTML="$HERE/../overlay.html"
fi
ICON_SRC="$HERE/icon.png"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found — install the Xcode command line tools: xcode-select --install" >&2
  exit 1
}

# the launcher runs status.sh with /bin/bash, which is 3.2 on macOS. 3.2 has a
# parser bug the 5.x in PATH does not: a lone apostrophe inside a here-doc that
# sits in $( ) swallows the rest of the file, and the HUD then gets zero bytes
# and paints every chip red while the native brain push still shows a score.
# lint with the interpreter that actually runs it, before shipping a build.
LINT_FAIL=0
for d in "$HERE/.." "$HERE/../scripts"; do
  [ -d "$d" ] || continue
  for n in status.sh api-keys.sh overlay-ctl.sh; do
    f="$d/$n"
    [ -f "$f" ] || continue
    if ! err=$(/bin/bash -n "$f" 2>&1); then
      echo "syntax error (macOS /bin/bash 3.2): $f" >&2
      printf '%s\n' "$err" >&2
      LINT_FAIL=1
    fi
  done
done
[ "$LINT_FAIL" = 0 ] || exit 1

# the panel is three thousand lines of one html with no build step, so a bad
# edit compiles fine and only shows up as silence. two shapes have already
# bitten: a duplicated event branch (an edit that landed twice) and a
# duplicated function (the second silently wins). both are cheap to refuse.
if ! err=$(python3 - "$HTML" <<'PY'
import re, sys, collections
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
branches = re.findall(r'ev\.type === "([a-zA-Z]+)"', src)
for name, n in collections.Counter(branches).items():
    if n > 1:
        bad.append(f'duplicate event branch: ev.type === "{name}" ({n}x)')
fns = re.findall(r'^function\s+([A-Za-z_$][\w$]*)\s*\(', src, re.M)
for name, n in collections.Counter(fns).items():
    if n > 1:
        bad.append(f'duplicate function: {name}() ({n}x)')
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
); then
  echo "overlay.html:" >&2
  printf '%s\n' "$err" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

# -swift-version 5 keeps the concurrency checker out of the way: this app is a
# single-threaded AppKit loop with two dispatch hops, nothing more.
swiftc -O -swift-version 5 \
  -o "$OUT/Contents/MacOS/$BIN_NAME" "$SRC" \
  -framework Cocoa -framework WebKit

cp "$HTML" "$OUT/Contents/Resources/overlay.html"
[ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$OUT/Contents/Resources/icon.png"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpencodeOverlay</string>
  <key>CFBundleDisplayName</key><string>Opencode Unlimited</string>
  <key>CFBundleIdentifier</key><string>com.opencode-unlimited.overlay</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>opencode-unlimited-overlay</string>
  <key>CFBundleIconFile</key><string>icon.png</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# ad-hoc signature so macOS keeps the same identity across rebuilds (otherwise
# every rebuild looks like a new app to TCC and to `open`)
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo "$OUT"
