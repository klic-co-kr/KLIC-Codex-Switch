#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -q 'private func statusIdleTitle() -> String' Sources/main.swift \
  || fail "status item should have a non-empty fallback title"
grep -q 'button.title = statusIdleTitle()' Sources/main.swift \
  || fail "status item should show fallback text before accounts load"
perl -0ne 'exit(/else \{\s*if !isSwitching \{\s*statusItem\.button\?\.title = statusIdleTitle\(\)/s ? 0 : 1)' Sources/main.swift \
  || fail "status item should remain visible when no active account is loaded"
grep -q 'Bundle.main.url(forResource: "AppIcon", withExtension: "icns")' Sources/main.swift \
  || fail "status item should prefer the bundled app icon"
perl -0ne 'exit(/statusTitle\(for account: CodexAccount\).*status_5hr.*displayLabel\(for: account\).*fiveHourUsedPercent/s ? 0 : 1)' Sources/main.swift \
  || fail "active status title should show the active account label plus 5-hour usage"
! grep -q '"KLIC"' Sources/main.swift \
  || fail "KLIC should not be shown in the app status title"

printf 'ok\n'
