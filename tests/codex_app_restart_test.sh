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
grep -q 'return cliRestartCodexAppProcess(launchIfNotRunning: launchIfNotRunning)' Sources/main.swift \
  || fail "account switch should restart the complete Codex app after auth swap"
! grep -q 'cliCodexAppServerPIDs' Sources/main.swift \
  || fail "account switch must not kill only the app-server child"
grep -q 'Codex restores its persisted window' Sources/main.swift \
  || fail "account switch should document persisted workspace/thread restoration"
grep -q 'cliRun("/usr/bin/open", \["-b", codexBundleIdentifier\])' Sources/main.swift \
  || fail "Codex app should launch by bundle ID"
! grep -q '/Applications/Codex\\.app/Contents/' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex.app path"
! grep -q 'application \\"Codex\\" is running' Sources/main.swift \
  || fail "relaunch must not depend on the old Codex display name"
! grep -q 'codex://threads/new' Sources/main.swift \
  || fail "account switch must not create a new thread"
grep -q 'alert_target_auth_refresh_failed_msg' Sources/main.swift \
  || fail "revoked target credentials must fail closed before auth swap"

printf 'ok\n'
