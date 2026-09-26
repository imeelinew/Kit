#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-pinyin-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Kit/Core/Pinyin.swift" \
    "$repo_root/tests/PinyinTests.swift" \
    -o "$test_dir/pinyin-tests"
"$test_dir/pinyin-tests"
