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
grep -q 'button.image = loadStatusBarIcon()' Sources/main.swift \
  || fail "status item should use an image icon"
grep -q 'private func makeKlicSwitcherStatusIcon() -> NSImage' Sources/main.swift \
  || fail "status item should draw an original KLIC switcher icon"
! grep -q '/Applications/Codex.app/Contents/Resources/codexTemplate' Sources/main.swift \
  || fail "status item should not reuse Codex app template resources"
grep -q 'image.isTemplate = true' Sources/main.swift \
  || fail "status icon should be a template image for menu bar contrast"
! grep -q 'Look for the \\"Codex\\" item' Resources/en.lproj/Localizable.strings \
  || fail "first-launch hint should not tell users to look for a Codex menu bar item"
! grep -q '메뉴바에서 \\"Codex\\"' Resources/ko.lproj/Localizable.strings \
  || fail "Korean first-launch hint should not tell users to look for a Codex menu bar item"
perl -0ne 'exit(/statusTitle\(for account: CodexAccount\).*status_5hr.*displayLabel\(for: account\).*fiveHourUsedPercent/s ? 0 : 1)' Sources/main.swift \
  || fail "active status title should show the active account label plus 5-hour usage"
! grep -q '"KLIC"' Sources/main.swift \
  || fail "KLIC should not be shown in the app status title"

printf 'ok\n'
