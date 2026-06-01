#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

main_app="$(./build.sh)"
[[ -d "$main_app" ]] || fail "main app should be built"
[[ -f "$root/Resources/AppIconSource.png" ]] || fail "project icon source PNG should exist"
[[ -f "$main_app/Contents/Resources/AppIcon.icns" ]] || fail "main app should include AppIcon.icns"

icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$main_app/Contents/Info.plist")"
[[ "$icon_name" == "AppIcon" ]] || fail "main app CFBundleIconFile should be AppIcon"

installer_app="$($root/build-installer.sh)"
[[ -d "$installer_app" ]] || fail "installer app should be built"
[[ -x "$installer_app/Contents/MacOS/CodexAccountSwitcherInstaller" ]] || fail "installer executable should exist"
[[ -d "$installer_app/Contents/Resources/Codex Account Switcher.app" ]] || fail "installer should embed the app"
[[ -f "$installer_app/Contents/Resources/AppIcon.icns" ]] || fail "installer should include icon"

installer_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$installer_app/Contents/Info.plist")"
[[ "$installer_icon_name" == "AppIcon" ]] || fail "installer CFBundleIconFile should be AppIcon"

printf 'ok\n'
