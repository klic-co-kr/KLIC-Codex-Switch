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
grep -q 'private let statusItemLength: CGFloat = 18' Sources/main.swift \
  || fail "status item should use a very compact fixed length so it fits in a crowded menu bar"
grep -q 'NSStatusBar.system.statusItem(withLength: statusItemLength)' Sources/main.swift \
  || fail "status item should be created with the compact fixed length"
grep -q 'private let statusItemAutosaveName = "local.codex-account-switcher.menu-bar.status-item"' Sources/main.swift \
  || fail "status item should use a stable autosave name so macOS persists visibility predictably"
grep -q 'private let statusItemPreferredPosition = 247' Sources/main.swift \
  || fail "status item should seed a right-side preferred position"
grep -q 'prepareStatusItemPlacementDefaults()' Sources/main.swift \
  || fail "status item placement defaults should be prepared before creation"
grep -q 'defaults.set(statusItemPreferredPosition, forKey: "NSStatusItem Preferred Position' Sources/main.swift \
  || fail "status item should persist a preferred position to avoid overflow placement"
grep -q 'defaults.set(true, forKey: "NSStatusItem Visible' Sources/main.swift \
  || fail "status item should persist visibility"
perl -0ne 'exit(/prepareStatusItemPlacementDefaults\(\).*statusItem = NSStatusBar\.system\.statusItem\(withLength: statusItemLength\).*statusItem\.autosaveName = statusItemAutosaveName.*statusItem\.isVisible = true/s ? 0 : 1)' Sources/main.swift \
  || fail "status item should set autosave name before forcing visibility"
grep -q 'button.title = ""' Sources/main.swift \
  || fail "status item should not consume menu bar width with visible text"
grep -q 'button.image = loadStatusBarIcon()' Sources/main.swift \
  || fail "status item should use an image icon"
grep -q 'button.imagePosition = .imageOnly' Sources/main.swift \
  || fail "status item should be icon-only"
perl -0ne 'exit(/private func loadStatusBarIcon\(\) -> NSImage\? \{\s*makeKlicSwitcherStatusIcon\(\)\s*\}/s ? 0 : 1)' Sources/main.swift \
  || fail "status item should use the original K icon as the primary menu bar image"
! grep -q 'arrow.left.arrow.right.circle.fill' Sources/main.swift \
  || fail "status item should not replace the K icon with a generic SF Symbol"
grep -q 'private func makeKlicSwitcherStatusIcon() -> NSImage' Sources/main.swift \
  || fail "status item should draw the original K icon"
! grep -q '/Applications/Codex.app/Contents/Resources/codexTemplate' Sources/main.swift \
  || fail "status item should not reuse Codex app template resources"
grep -q 'image.isTemplate = true' Sources/main.swift \
  || fail "status icon should be a template image for menu bar contrast"
! grep -q 'Look for the \\"Codex\\" item' Resources/en.lproj/Localizable.strings \
  || fail "first-launch hint should not tell users to look for a Codex menu bar item"
! grep -q '메뉴바에서 \\"Codex\\"' Resources/ko.lproj/Localizable.strings \
  || fail "Korean first-launch hint should not tell users to look for a Codex menu bar item"
perl -0ne 'exit(/if let active = accounts\.first\(where: \{ \$0\.isActive \}\) \{\s*if !isSwitching \{\s*statusItem\.button\?\.toolTip = statusTitle\(for: active\)/s ? 0 : 1)' Sources/main.swift \
  || fail "status item should expose the active account label in the tooltip"
perl -0ne 'exit(/else \{\s*if !isSwitching \{\s*statusItem\.button\?\.toolTip = statusIdleTitle\(\)/s ? 0 : 1)' Sources/main.swift \
  || fail "status item should expose fallback text in the tooltip when no active account is loaded"
perl -0ne 'exit(/statusTitle\(for account: CodexAccount\).*status_5hr.*displayLabel\(for: account\).*fiveHourUsedPercent/s ? 0 : 1)' Sources/main.swift \
  || fail "active tooltip title should show the active account label plus 5-hour usage"
! grep -q '"KLIC"' Sources/main.swift \
  || fail "KLIC should not be shown in the app status title"

printf 'ok\n'
