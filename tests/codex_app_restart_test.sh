#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

grep -q 'private let codexBundleIdentifier = "com.openai.codex"' Sources/main.swift \
  || fail "Codex app should be identified by its bundle ID"
grep -q 'NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)' Sources/main.swift \
  || fail "running Codex app should be found by bundle ID"
grep -q 'cliCodexProcessIdentities(rootPIDs: rootPIDs)' Sources/main.swift \
  || fail "restart should snapshot the Codex process tree before termination"
grep -q 'currentIdentity == expectedIdentity' Sources/main.swift \
  || fail "restart should revalidate process identity before signaling"
grep -q 'processIdentities.count != initialTree.count' Sources/main.swift \
  || fail "restart should fail closed when a process identity cannot be verified"
grep -q '\.terminate()' Sources/main.swift \
  || fail "restart should request graceful app termination first"
grep -q 'cliRun("/usr/bin/open", \["-b", codexBundleIdentifier\])' Sources/main.swift \
  || fail "Codex app should launch by bundle ID"
grep -q 'components.host = "threads"' Sources/main.swift \
  || fail "restart should use Codex workspace deep link host"
grep -q 'URLQueryItem(name: "path", value: path)' Sources/main.swift \
  || fail "workspace deep link should carry saved path as query"
grep -q 'electron-saved-workspace-roots' Sources/main.swift \
  || fail "restart should read saved workspace roots"
! grep -q '/Applications/Codex\\.app/Contents/' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex.app path"
! grep -q 'application \\"Codex\\" is running' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex display name"

printf 'ok\n'
