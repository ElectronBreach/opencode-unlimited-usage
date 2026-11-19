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
HTML="$HERE/overlay.html"
ICON_SRC="$HERE/icon.png"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found — install the Xcode command line tools: xcode-select --install" >&2
  exit 1
}

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
