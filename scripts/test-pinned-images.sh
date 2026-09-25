#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-pinned-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 \
    "$repo_root/Kit/Features/Clipboard/PinnedImageGeometry.swift" \
    "$repo_root/Kit/Features/Clipboard/PinnedImagePanel.swift" \
    "$repo_root/tests/PinnedImageSizingTests.swift" \
    -o "$test_dir/pinned-image-tests"
"$test_dir/pinned-image-tests"
