#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$("$root/build.sh")/Contents/MacOS/CodexAccountSwitcher"
suite="rotation-fallback-test-$RANDOM-$$"

run() {
  CODEX_SWITCHER_DEFAULTS_SUITE="$suite" "$bin" "$@"
}

# Thresholds are remaining %: switch when remaining <= threshold.
run rotation threshold5h 20 | grep -qx 'thr5h:20' || fail "set thr5h"
run rotation thresholdWeekly 20 | grep -qx 'thrWeekly:20' || fail "set thrWeekly"

status="$(run rotation status)"
[[ "$status" == "rotation:off thr5h:20 thrWeekly:20" ]] || fail "status mismatch: $status"

# decide <active5h> <activeWeekly> <inactive5h> <inactiveWeekly>  (used %, '-' unknown)
# active 5h used 85 -> remaining 15 <= 20 => over; inactive healthy => switch
[[ "$(run rotation decide 85 10 10 10)" == "switch" ]] || fail "5h trigger should switch"
# active weekly used 85 -> remaining 15 over; inactive healthy => switch
[[ "$(run rotation decide 10 85 10 10)" == "switch" ]] || fail "weekly trigger should switch"
# active over, inactive 5h used 90 -> also over => all-exhausted
[[ "$(run rotation decide 85 10 90 10)" == "all-exhausted" ]] || fail "both over should be all-exhausted"
# both healthy => none
[[ "$(run rotation decide 50 50 50 50)" == "none" ]] || fail "healthy should be none"
# active windows unknown => not over => none
[[ "$(run rotation decide - - 10 10)" == "none" ]] || fail "unknown active should be none"
# active 5h over, inactive windows unknown => inactive not over => switch
[[ "$(run rotation decide 90 10 - -)" == "switch" ]] || fail "unknown inactive counts as healthy"
# boundary: remaining exactly equals threshold (used 80 -> rem 20 <= 20) => over
[[ "$(run rotation decide 80 10 10 10)" == "switch" ]] || fail "remaining == threshold is over"
# just above: used 79 -> rem 21 > 20 => not over => none
[[ "$(run rotation decide 79 10 10 10)" == "none" ]] || fail "remaining just above threshold is not over"

printf 'ok\n'
