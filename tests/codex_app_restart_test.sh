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
grep -q 'cliCodexAppServerPIDs(rootPIDs: rootPIDs)' Sources/main.swift \
  || fail "account switch should reconnect the app-server child without closing the app"
grep -q 'cliWaitForCodexAppServer' Sources/main.swift \
  || fail "account switch should wait for the replacement app-server"
grep -q 'cliRun("/usr/bin/open", \["-b", codexBundleIdentifier\])' Sources/main.swift \
  || fail "Codex app should launch by bundle ID"
! grep -q '/Applications/Codex\\.app/Contents/' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex.app path"
! grep -q 'application \\"Codex\\" is running' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex display name"
! grep -q 'codex://threads/new' Sources/main.swift \
  || fail "account switch must not create a new thread"

printf 'ok\n'
