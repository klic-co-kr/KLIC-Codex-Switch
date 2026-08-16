#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# waitForOAuthCallback must be bounded: a blocking accept() on a Darwin
# listening socket ignores SO_RCVTIMEO and parks the login thread forever,
# leaving isSwitching stuck and disabling every account switch.

perl -0ne 'exit(/private func waitForOAuthCallback\(port: UInt16, expectedState: String, codeVerifier: String, timeout: TimeInterval = 300\)/ ? 0 : 1)' Sources/main.swift \
  || fail "waitForOAuthCallback should take a timeout parameter (default 300s)"

perl -0ne 'exit(/waitForOAuthCallback.*?O_NONBLOCK/s ? 0 : 1)' Sources/main.swift \
  || fail "listening socket should be set non-blocking before accept"

perl -0ne 'exit(/waitForOAuthCallback.*?while Date\(\) < deadline.*?accept\(sock, nil, nil\).*?EWOULDBLOCK/s ? 0 : 1)' Sources/main.swift \
  || fail "accept should be polled against a deadline and tolerate EWOULDBLOCK"

grep -q 'setsockopt(client, SOL_SOCKET, SO_RCVTIMEO' Sources/main.swift \
  || fail "accepted client socket should get its own receive timeout before recv"

! grep -q 'let client = accept(sock, nil, nil)$' Sources/main.swift \
  || fail "must not keep a bare blocking accept() call"

! grep -q 'setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO' Sources/main.swift \
  || fail "SO_RCVTIMEO on the listening socket is dead code on Darwin and should be removed"

printf 'ok\n'
