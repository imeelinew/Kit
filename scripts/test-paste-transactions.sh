#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-paste-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Kit/Core/PasteTransaction.swift" \
    "$repo_root/tests/PasteTransactionTests.swift" \
    -o "$test_dir/paste-transaction-tests"
"$test_dir/paste-transaction-tests"
