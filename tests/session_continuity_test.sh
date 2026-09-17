#!/bin/bash
# Session continuity integration test — drives the CLI session subcommands
# against an isolated CODEX_SWITCHER_HOME so the real ~/.codex is never touched.
set -u

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$("$ROOT_DIR/build.sh")/Contents/MacOS/CodexAccountSwitcher"

export CODEX_SWITCHER_HOME="$(mktemp -d)"
export CODEX_SWITCHER_DEFAULTS_SUITE="test-session-continuity-$RANDOM-$$"
export CODEX_SWITCHER_VERIFY_CHAIN=off
trap 'rm -rf "$CODEX_SWITCHER_HOME"; rm -f "$HOME/Library/Preferences/$CODEX_SWITCHER_DEFAULTS_SUITE.plist"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$CODEX_SWITCHER_HOME/.codex/accounts" "$CODEX_SWITCHER_HOME/.codex/sessions/2026/08/17"
echo '{"tokens":{"access_token":"x"},"auth_mode":"chatgpt"}' > "$CODEX_SWITCHER_HOME/.codex/auth.json"
echo '{"active_account_key":"a@example.com"}' > "$CODEX_SWITCHER_HOME/.codex/accounts/registry.json"
echo '{"tokens":{"access_token":"a"}}' > "$CODEX_SWITCHER_HOME/.codex/accounts/$(echo -n 'a@example.com' | base64 | tr -d '=').auth.json"
echo '{"tokens":{"access_token":"b"}}' > "$CODEX_SWITCHER_HOME/.codex/accounts/$(echo -n 'b@example.com' | base64 | tr -d '=').auth.json"
echo '{"session":"older than marker"}' > "$CODEX_SWITCHER_HOME/.codex/sessions/2026/08/17/rollout-2026-08-17-abcdef01-1234-5678-9abc-def012345678.jsonl"
echo 'prefix history line' > "$CODEX_SWITCHER_HOME/.codex/history.jsonl"

# 1. protection defaults to on
out="$("$BIN" session protection)" || fail "session protection status failed"
[[ "$out" == "protection:on" ]] || fail "expected protection:on, got: $out"

# 2. protection off/on round-trip
"$BIN" session protection off || fail "protection off failed"
out="$("$BIN" session protection)" || fail "status read failed"
[[ "$out" == "protection:off" ]] || fail "expected protection:off, got: $out"
"$BIN" session protection on || fail "protection on failed"

# 3. snapshot captures protected entries (sessions dir + history.jsonl)
out="$("$BIN" session snapshot)" || fail "snapshot failed"
[[ "$out" == entries:* ]] || fail "unexpected snapshot output: $out"
entries="${out#entries:}"
entries="${entries%% *}"
[[ "$entries" -ge 2 ]] || fail "expected at least 2 snapshot entries, got: $out"

# 4. continuity begin prints a CAS-PROBE marker
out="$("$BIN" session continuity begin)" || fail "continuity begin failed"
[[ "$out" == marker:CAS-PROBE-* ]] || fail "unexpected marker output: $out"
marker="${out#marker:}"

# 5. marker not yet in session files -> not-found
if "$BIN" session continuity locate; then
  fail "locate should fail before the marker exists in session files"
fi

# 6. write the marker into a session file the way Codex would
echo "user message containing $marker" >> "$CODEX_SWITCHER_HOME/.codex/sessions/2026/08/17/rollout-2026-08-17-abcdef01-1234-5678-9abc-def012345678.jsonl"
out="$("$BIN" session continuity locate)" || fail "locate failed after inserting marker"
[[ "$out" == "marker:found"* ]] || fail "expected marker:found, got: $out"
[[ "$out" == *"session:abcdef01-1234-5678-9abc-def012345678"* ]] || fail "session id not inferred: $out"

# 7. finish records the verdict
out="$("$BIN" session continuity finish pass)" || fail "finish failed"
[[ "$out" == "verdict:pass"* ]] || fail "unexpected finish output: $out"

# 8. legacy records persisted with Korean verdict raw values still decode
record_file="$CODEX_SWITCHER_HOME/.codex/continuity/continuity-test.json"
sed -i '' 's/"verdict": "pass"/"verdict": "통과"/' "$record_file"
out="$("$BIN" session continuity locate)" || fail "legacy verdict record failed to decode"
[[ "$out" == "marker:found"* ]] || fail "legacy verdict locate failed: $out"

# 9. switch smoke test with protection on — exercises the fail-closed snapshot
#    captures and both checks on a healthy tree (no Codex app restart).
"$BIN" scope app off || fail "scope app off failed"
out="$("$BIN" switch b@example.com)" || fail "switch with session protection failed"
[[ "$out" == "switched:b@example.com" ]] || fail "unexpected switch output: $out"
active="$("$BIN" active)" || fail "active read failed after switch"
[[ "$active" == "b@example.com" ]] || fail "registry/auth disagree after switch: active=$active"
[[ "$(tr -d ' ' < "$CODEX_SWITCHER_HOME/.codex/auth.json")" == *'"access_token":"b"'* ]] || fail "auth.json not swapped to b"

# 10. protection off skips both checks (regression for the toggle gating)
"$BIN" session protection off || fail "protection off failed"
out="$("$BIN" switch a@example.com)" || fail "switch with protection off failed"
[[ "$out" == "switched:a@example.com" ]] || fail "unexpected switch-back output: $out"

echo "✓ session continuity test passed"
