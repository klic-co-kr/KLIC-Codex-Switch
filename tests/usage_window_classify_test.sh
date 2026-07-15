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

classify() {
  printf '%s' "$1" > "$tmp/u.json"
  "$bin" usage parse "$tmp/u.json"
}

# Current API (2026-07): 5-hour window removed, weekly delivered in primary_window,
# secondary null. Weekly (604800s) must NOT be reported as 5h.
out="$(classify '{"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":604800,"reset_at":1784666226},"secondary_window":null}}')"
[[ "$out" == "5h:- weekly:15" ]] || fail "weekly-only should map to weekly, got: $out"

# Legacy shape: primary=5h (18000s), secondary=weekly (604800s).
out="$(classify '{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000},"secondary_window":{"used_percent":70,"limit_window_seconds":604800}}}')"
[[ "$out" == "5h:40 weekly:70" ]] || fail "legacy 5h+weekly mapping, got: $out"

# Reversed slots: weekly in primary, 5h in secondary — classification by duration must still be correct.
out="$(classify '{"rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":604800},"secondary_window":{"used_percent":40,"limit_window_seconds":18000}}}')"
[[ "$out" == "5h:40 weekly:70" ]] || fail "reversed slots must classify by duration, got: $out"

# No duration field: fall back to positional (primary->5h, secondary->weekly).
out="$(classify '{"rate_limit":{"primary_window":{"used_percent":22},"secondary_window":{"used_percent":88}}}')"
[[ "$out" == "5h:22 weekly:88" ]] || fail "positional fallback when duration absent, got: $out"

# window_minutes variant (300 min = 5h).
out="$(classify '{"rate_limit":{"primary_window":{"utilization":33,"window_minutes":300}}}')"
[[ "$out" == "5h:33 weekly:-" ]] || fail "window_minutes 300 should be 5h, got: $out"

# Empty rate limit.
out="$(classify '{"rate_limit":{"primary_window":null,"secondary_window":null}}')"
[[ "$out" == "5h:- weekly:-" ]] || fail "empty windows, got: $out"

printf 'ok\n'
