#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$("$root/build.sh")/Contents/MacOS/CodexAccountSwitcher"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
suite="switch-scope-test-$RANDOM-$$"
accounts="$home/.codex/accounts"
mkdir -p "$accounts"

one_key="$(printf 'one@example.com' | base64 | tr -d '=')"
two_key="$(printf 'two@example.com' | base64 | tr -d '=')"
cat > "$accounts/registry.json" <<JSON
{
  "active_account_key": "one@example.com"
}
JSON
cat > "$accounts/$one_key.auth.json" <<JSON
{
  "auth_mode": "chatgpt",
  "tokens": {
    "access_token": "one-token"
  }
}
JSON
cat > "$accounts/$two_key.auth.json" <<JSON
{
  "auth_mode": "chatgpt",
  "tokens": {
    "access_token": "two-token"
  }
}
JSON
cp "$accounts/$one_key.auth.json" "$home/.codex/auth.json"

status="$(CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope status)"
[[ "$status" == "cli:on app:on launch:off" ]] || fail "default scope status should be cli:on app:on launch:off, got: $status"

CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope app off | grep -qx 'app:off' || fail "scope app off should print app:off"
status="$(CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope status)"
[[ "$status" == "cli:on app:off launch:off" ]] || fail "app off status mismatch: $status"

switch_output="$(CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" switch two@example.com 2>&1)"
[[ "$switch_output" == "switched:two@example.com" ]] || fail "switch with app reflection off should not relaunch or warn, got: $switch_output"
grep -q 'two-token' "$home/.codex/auth.json" || fail "switch should still update CLI next-run auth"

CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope launch on | grep -qx 'launch:on' || fail "scope launch on should print launch:on"
CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope cli off | grep -qx 'cli:off' || fail "scope cli off should print cli:off"
status="$(CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" scope status)"
[[ "$status" == "cli:off app:off launch:on" ]] || fail "final scope status mismatch: $status"

if CODEX_SWITCHER_DEFAULTS_SUITE="$suite" CODEX_SWITCHER_HOME="$home" HOME="$home" "$bin" switch one@example.com >"$tmp/switch-disabled.out" 2>&1; then
  fail "switch should fail when CLI next-run apply is off"
fi
grep -q 'CLI next-run apply is off' "$tmp/switch-disabled.out" || fail "disabled switch should explain CLI next-run apply is off"

printf 'ok\n'
