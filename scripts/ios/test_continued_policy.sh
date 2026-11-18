#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ykt-ios-policy.XXXXXX")"
trap 'rm -f "$test_dir/policy-tests"; rmdir "$test_dir"' EXIT
swiftc "$workspace_root/ios/Runner/IOSContinuedTaskPolicy.swift" \
  "$workspace_root/ios/native-tests/main.swift" -o "$test_dir/policy-tests"
"$test_dir/policy-tests"
