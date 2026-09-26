#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-capture-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Kit/Core/ClipboardCapturePipeline.swift" \
    "$repo_root/tests/ClipboardCaptureTests.swift" \
    -o "$test_dir/capture-tests"
"$test_dir/capture-tests"
