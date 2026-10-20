#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/DockNumberShortcut.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"

/usr/bin/clang \
  -fobjc-arc \
  -mmacosx-version-min=10.15 \
  -fmodules-cache-path=/private/tmp/dock-number-shortcut-module-cache \
  "$ROOT/main.m" \
  -o "$MACOS/DockNumberShortcut" \
  -framework Cocoa \
  -framework Carbon

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Dock 数字快捷键</string>
    <key>CFBundleExecutable</key>
    <string>DockNumberShortcut</string>
    <key>CFBundleIdentifier</key>
    <string>local.dock-number-shortcut</string>
    <key>CFBundleName</key>
    <string>DockNumberShortcut</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built: $APP"
