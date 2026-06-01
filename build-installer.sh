#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
INSTALLER_NAME="Codex Account Switcher Installer"
INSTALLER_DIR="$BUILD_DIR/$INSTALLER_NAME.app"
CONTENTS_DIR="$INSTALLER_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_PATH="$MACOS_DIR/CodexAccountSwitcherInstaller"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
MAIN_APP_PATH="$("$ROOT_DIR/build.sh")"

rm -rf "$INSTALLER_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

cp -R "$MAIN_APP_PATH" "$RESOURCES_DIR/Codex Account Switcher.app"
if [[ -f "$MAIN_APP_PATH/Contents/Resources/AppIcon.icns" ]]; then
  cp "$MAIN_APP_PATH/Contents/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc "$ROOT_DIR/Installer/main.swift" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -o "$BIN_PATH"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleExecutable</key>
  <string>CodexAccountSwitcherInstaller</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex-account-switcher.installer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Account Switcher Installer</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Account Switcher 설치</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

echo "$INSTALLER_DIR"
