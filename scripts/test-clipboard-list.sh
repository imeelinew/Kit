#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-list-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
build_dir=${KIT_TEST_BUILD_DIR:-"$test_dir/build"}

xcodebuild -quiet -project "$repo_root/Kit.xcodeproj" -scheme Kit \
    -configuration Debug -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=YES build

products="$build_dir/Build/Products/Debug"
packages="$build_dir/SourcePackages/checkouts"
xcrun swiftc -swift-version 6 -parse-as-library \
    -I "$products" -F "$products" -F "$products/PackageFrameworks" \
    -Xcc -I"$packages/swift-cmark/src/include" \
    -Xcc -I"$packages/swift-cmark/extensions/include" \
    -Xcc -fmodule-map-file="$packages/swift-cmark/src/include/module.modulemap" \
    -Xcc -fmodule-map-file="$packages/swift-cmark/extensions/include/module.modulemap" \
    -Xcc -fmodule-map-file="$packages/swift-markdown/Sources/CAtomic/include/module.modulemap" \
    -Xlinker -rpath -Xlinker "$products/Kit.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$products" \
    "$products/Kit.app/Contents/MacOS/Kit.debug.dylib" \
    "$repo_root/tests/ClipboardListAnimationTests.swift" \
    "$repo_root/tests/ClipboardUndoTests.swift" \
    -o "$test_dir/clipboard-list-tests"
"$test_dir/clipboard-list-tests"
