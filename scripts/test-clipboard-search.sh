#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-search-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Kit/Core/ClipboardStore.swift" \
    "$repo_root/Kit/Core/ClipboardItem.swift" \
    "$repo_root/Kit/Core/ClipboardSQLite.swift" \
    "$repo_root/Kit/Core/ClipboardSearch.swift" \
    "$repo_root/Kit/Core/Pinyin.swift" \
    "$repo_root/Kit/Core/ImageThumbnail.swift" \
    "$repo_root/tests/ClipboardSearchTests.swift" \
    -o "$test_dir/clipboard-search-tests"
"$test_dir/clipboard-search-tests"
