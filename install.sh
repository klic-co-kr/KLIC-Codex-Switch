#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$(/bin/bash "$ROOT_DIR/build.sh")"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/Codex Account Switcher.app"
LABEL="local.codex-account-switcher.menu-bar"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
EXECUTABLE="$DEST_APP/Contents/MacOS/CodexAccountSwitcher"

if [[ "${INSTALL_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  /bin/launchctl bootout "gui/$UID" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  /usr/bin/pkill -x CodexAccountSwitcher >/dev/null 2>&1 || true
fi

mkdir -p "$DEST_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
rm -rf "$DEST_APP"
cp -R "$APP_PATH" "$DEST_APP"

cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/CodexAccountSwitcher.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/CodexAccountSwitcher.error.log</string>
</dict>
</plist>
PLIST

if [[ "${INSTALL_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  /bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
  /bin/launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1 || true
fi

echo "$DEST_APP"
