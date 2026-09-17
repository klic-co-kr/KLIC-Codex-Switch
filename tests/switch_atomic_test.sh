#!/usr/bin/env bash
# Atomicity, single-writer lock, and rollback integration test — drives the
# CLI switch path against an isolated CODEX_SWITCHER_HOME so the real ~/.codex
# is never touched.
set -u

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$("$ROOT_DIR/build.sh")/Contents/MacOS/CodexAccountSwitcher"

export CODEX_SWITCHER_HOME="$(mktemp -d)"
export CODEX_SWITCHER_DEFAULTS_SUITE="test-switch-atomic-$RANDOM-$$"
trap 'rm -rf "$CODEX_SWITCHER_HOME"; rm -f "$HOME/Library/Preferences/$CODEX_SWITCHER_DEFAULTS_SUITE.plist"' EXIT

accounts="$CODEX_SWITCHER_HOME/.codex/accounts"
mkdir -p "$accounts"

one_key="$(printf 'one@example.com' | base64 | tr -d '=')"
two_key="$(printf 'two@example.com' | base64 | tr -d '=')"
echo '{"active_account_key":"one@example.com"}' > "$accounts/registry.json"
echo '{"tokens":{"access_token":"one-token"},"auth_mode":"chatgpt"}' > "$accounts/$one_key.auth.json"
echo '{"tokens":{"access_token":"two-token"},"auth_mode":"chatgpt"}' > "$accounts/$two_key.auth.json"
echo '{"tokens":{"access_token":"one-token"},"auth_mode":"chatgpt"}' > "$CODEX_SWITCHER_HOME/.codex/auth.json"

# App reflection off so no Codex launch is attempted in the sandbox.
CODEX_SWITCHER_DEFAULTS_SUITE="$CODEX_SWITCHER_DEFAULTS_SUITE" "$BIN" scope app off >/dev/null || fail "scope app off"

run_switch() {
  CODEX_SWITCHER_VERIFY_CHAIN="$1" "$BIN" switch two@example.com 2>&1
}

# --- 1. Lock held by a live process blocks the switch -------------------
lock="$CODEX_SWITCHER_HOME/.codex/.account-switch.lock"
python3 -c "import struct,sys; open('$lock','wb').write(struct.pack('i', $$))"
out="$(run_switch off)"
status=$?
[[ $status -ne 0 ]] || fail "switch should fail while a live lock is held, got rc=0: $out"
echo "$out" | grep -q "in progress" || fail "held lock should explain switch in progress, got: $out"
grep -q 'one-token' "$CODEX_SWITCHER_HOME/.codex/auth.json" || fail "auth.json must be untouched when lock is held"
rm -f "$lock"

# --- 2. Stale lock (dead owner PID) is reclaimed ------------------------
sh -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null
python3 -c "import struct; open('$lock','wb').write(struct.pack('i', $dead_pid))"
out="$(CODEX_SWITCHER_VERIFY_CHAIN=off "$BIN" switch two@example.com 2>&1)"
[[ "$out" == "switched:two@example.com" ]] || fail "stale lock should be reclaimed and switch succeed, got: $out"
grep -q 'two-token' "$CODEX_SWITCHER_HOME/.codex/auth.json" || fail "auth.json should hold target token after switch"
[[ ! -e "$lock" ]] || fail "lock file must be released after switch"

# --- 3. auth.json permissions are 0600 after atomic write ---------------
perm="$(stat -f '%Lp' "$CODEX_SWITCHER_HOME/.codex/auth.json")"
[[ "$perm" == "600" ]] || fail "auth.json must be 0600 after atomic write, got: $perm"

# --- 4. Switch back to one to set up rollback test ----------------------
out="$(CODEX_SWITCHER_VERIFY_CHAIN=off "$BIN" switch one@example.com 2>&1)"
[[ "$out" == "switched:one@example.com" ]] || fail "switch-back failed: $out"

# --- 5. Remote verification failure rolls back atomically ---------------
# Chain on, fixture Devin credential valid, but provider endpoint dead →
# verification must fail, auth.json + registry must return to one@example.com.
credfix="$CODEX_SWITCHER_HOME/devin-credentials.toml"
printf 'windsurf_api_key = "fixture-token"\n' > "$credfix"
out="$(CODEX_SWITCHER_DEVIN_CREDENTIALS="$credfix" \
      CODEX_SWITCHER_DEVIN_URL="http://127.0.0.1:9" \
      CODEX_SWITCHER_GATEWAY_URL="http://127.0.0.1:9" \
      "$BIN" switch two@example.com 2>&1)"
status=$?
[[ $status -ne 0 ]] || fail "unreachable provider must fail the switch, got rc=0: $out"
echo "$out" | grep -q "switch failed" || fail "failure must be reported, got: $out"
echo "$out" | grep -q "Rolled back" || fail "rollback must be reported, got: $out"
grep -q 'one-token' "$CODEX_SWITCHER_HOME/.codex/auth.json" || fail "auth.json must be restored to previous account"
python3 - "$accounts/registry.json" <<'EOF' || fail "registry must point back at one@example.com"
import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r.get("active_account_key") == "one@example.com" else 1)
EOF

# --- 6. Success still reported only when the whole chain passes ---------
# Point every check at fixtures that answer: skip via VERIFY_CHAIN=off is
# covered above; here the real endpoints are unreachable so success must NOT
# be printed. This proves 'switched:' is gated on verification, not on swap.
! echo "$out" | grep -q "switched:" || fail "switched: must never print on a failed chain"

printf 'ok\n'
