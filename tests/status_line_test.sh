#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

perl -0ne 'exit(/statusTitle\(for account: CodexAccount\).*status_5hr.*fiveHourUsedPercent/s ? 0 : 1)' Sources/main.swift \
  || fail "menu bar status should show 5-hour remaining only"
perl -0ne 'exit(/statusTitle\(for account: CodexAccount\).*?return base\n    \}/s && $& !~ /weeklyUsedPercent/ ? 0 : 1)' Sources/main.swift \
  || fail "menu bar status should not show weekly remaining"
grep -q 'usageCombinedItem(for: active)' Sources/main.swift \
  || fail "dropdown should keep combined usage row"
perl -0ne 'exit(/usageCombinedItem\(for account: CodexAccount\).*weeklyReset: resetTimeText\(from: account\.weeklyResetAt\)/s ? 0 : 1)' Sources/main.swift \
  || fail "weekly reset should include time in dropdown"

printf 'ok\n'
