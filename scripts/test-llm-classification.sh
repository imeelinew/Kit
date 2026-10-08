#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-llm-classification-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Kit/Core/LLMTextClassifier.swift" \
    "$repo_root/Kit/Core/AppSettings.swift" \
    "$repo_root/Kit/Core/LaunchAtLogin.swift" \
    "$repo_root/Kit/Core/ClipboardItem.swift" \
    "$repo_root/Kit/Core/ClipboardImageOCR.swift" \
    "$repo_root/Kit/Core/ClipboardStore.swift" \
    "$repo_root/Kit/Core/ClipboardSQLite.swift" \
    "$repo_root/Kit/Core/ClipboardSearch.swift" \
    "$repo_root/Kit/Core/Pinyin.swift" \
    "$repo_root/Kit/Core/ImageThumbnail.swift" \
    "$repo_root/Kit/Core/ClipboardRowThumbnailCache.swift" \
    "$repo_root/tests/LLMClassificationTests.swift" \
    -o "$test_dir/llm-classification-tests"
"$test_dir/llm-classification-tests"
