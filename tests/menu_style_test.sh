#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -q 'private func styledMenuIcon' Sources/main.swift \
  || fail "menu actions should use a shared SF Symbol icon helper"
grep -q 'private func activeSummaryItem(for account: CodexAccount)' Sources/main.swift \
  || fail "menu should include a custom active account summary row"
grep -q 'menu.addItem(activeSummaryItem(for: active))' Sources/main.swift \
  || fail "active account summary row should be added to the menu"
perl -0ne 'exit(/usageCombinedItem\(for account: CodexAccount\).*item\.view = usageSummaryView/s ? 0 : 1)' Sources/main.swift \
  || fail "usage row should render as a compact custom summary view"
grep -q 'private func usageValueColumn(title: String, value: String, accent: NSColor)' Sources/main.swift \
  || fail "usage summary should use unboxed value columns"
grep -q 'private func usageDetailTooltip' Sources/main.swift \
  || fail "usage details should be available on hover"
perl -0ne 'exit(/activeSummaryItem\(for account: CodexAccount\)(.*?)usageSummaryView/s && $1 !~ /background\.layer\?\.borderWidth|background\.layer\?\.backgroundColor|let background = NSView/ ? 0 : 1)' Sources/main.swift \
  || fail "active account summary should not render a boxed card"
! grep -q 'private func usageBadgeView' Sources/main.swift \
  || fail "usage remaining should not use boxed badge views"

printf 'ok\n'
