#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -q 'private var cachedUsageByAccount: \[String: ParsedUsage\]' Sources/main.swift \
  || fail "usage cache should preserve usage for every account"
grep -q 'self.cachedUsageByAccount = allUsage' Sources/main.swift \
  || fail "fresh usage fetch should update the full account usage cache"
grep -q 'let staleCache: \[String: ParsedUsage\]' Sources/main.swift \
  || fail "stale refresh path should reuse all cached account usage"
grep -q 'accountAttributedTitle(for: account)' Sources/main.swift \
  || fail "account rows should be rendered from the full account model"
perl -0ne 'exit(/accountAttributedTitle\(for account: CodexAccount\).*remainingPercentText\(fromUsed: account\.fiveHourUsedPercent\).*remainingPercentText\(fromUsed: account\.weeklyUsedPercent\)/s ? 0 : 1)' Sources/main.swift \
  || fail "account rows should include visible 5-hour and weekly usage"
perl -0ne 'exit(/accountAttributedTitle\(for account: CodexAccount\).*?return attributedColumns\((.*?)\n    \}/s && $1 !~ /account\.email/ ? 0 : 1)' Sources/main.swift \
  || fail "account rows should not show raw account ids or emails"
perl -0ne 'exit(/activeSummaryItem\(for account: CodexAccount\).*?let subtitle = menuLabel\((.*?)let plan/s && $1 !~ /account\.email/ ? 0 : 1)' Sources/main.swift \
  || fail "active summary should not show the raw account id or email"
grep -q 'private let menuSummaryWidth: CGFloat = 300' Sources/main.swift \
  || fail "menu summary width should be reduced"

printf 'ok\n'
