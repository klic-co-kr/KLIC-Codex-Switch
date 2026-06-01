#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

project="$tmp/project"
home="$tmp/home"
fake_app="$tmp/fake-build/Codex Account Switcher.app"
mkdir -p "$project" "$home" "$fake_app/Contents/MacOS"
touch "$fake_app/Contents/MacOS/CodexAccountSwitcher"
chmod +x "$fake_app/Contents/MacOS/CodexAccountSwitcher"

cp install.sh "$project/install.sh"
cat > "$project/build.sh" <<BUILD
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$fake_app"
BUILD
chmod +x "$project/build.sh"

output="$(INSTALL_SKIP_LAUNCHCTL=1 HOME="$home" "$project/install.sh")"
dest_app="$home/Applications/Codex Account Switcher.app"
agent="$home/Library/LaunchAgents/local.codex-account-switcher.menu-bar.plist"

[[ "$output" == "$dest_app" ]] || fail "installer should print installed app path"
[[ -d "$dest_app" ]] || fail "app should be copied to ~/Applications"
[[ -f "$agent" ]] || fail "LaunchAgent plist should be created"

/usr/libexec/PlistBuddy -c 'Print :Label' "$agent" | grep -qx 'local.codex-account-switcher.menu-bar' \
  || fail "LaunchAgent label should match bundle id"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent" | grep -qx "$dest_app/Contents/MacOS/CodexAccountSwitcher" \
  || fail "LaunchAgent should run installed executable"
/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$agent" | grep -qx 'true' \
  || fail "LaunchAgent should run at load"
/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$agent" | grep -qx 'false' \
  || fail "LaunchAgent should restart after abnormal termination only"

printf 'ok\n'
