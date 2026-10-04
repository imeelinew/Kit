#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-list-tests.XXXXXX")
bundle_id="com.eli.Kit.tests.clipboard-list.$(uuidgen)"
singleton_dir="$HOME/Library/Application Support/$bundle_id"
trap 'rm -rf "$test_dir" "$singleton_dir"' EXIT
build_dir=${KIT_TEST_BUILD_DIR:-"$test_dir/build"}

xcodebuild -quiet -project "$repo_root/Kit.xcodeproj" -scheme Kit \
    -configuration Debug -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=YES build

products="$build_dir/Build/Products/Debug"
packages="$build_dir/SourcePackages/checkouts"
ditto "$repo_root/Kit/en.lproj" "$test_dir/en.lproj"
ditto "$repo_root/Kit/zh-Hans.lproj" "$test_dir/zh-Hans.lproj"
# Hover feedback initializes the app singleton. Give the CLI harness its own
# bundle identity so its default store cannot point at the user's Kit history.
python3 - "$test_dir/bundle-info.plist" "$bundle_id" <<'PYCODE'
import plistlib
import sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump({"CFBundleIdentifier": sys.argv[2]}, output)
PYCODE
xcrun swiftc -swift-version 6 -parse-as-library \
    -I "$products" -F "$products" -F "$products/PackageFrameworks" \
    -Xcc -I"$packages/swift-cmark/src/include" \
    -Xcc -I"$packages/swift-cmark/extensions/include" \
    -Xcc -fmodule-map-file="$packages/swift-cmark/src/include/module.modulemap" \
    -Xcc -fmodule-map-file="$packages/swift-cmark/extensions/include/module.modulemap" \
    -Xcc -fmodule-map-file="$packages/swift-markdown/Sources/CAtomic/include/module.modulemap" \
    -Xlinker -rpath -Xlinker "$products/Kit.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$products" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$test_dir/bundle-info.plist" \
    "$products/Kit.app/Contents/MacOS/Kit.debug.dylib" \
    "$repo_root/tests/ClipboardListAnimationTests.swift" \
    "$repo_root/tests/ClipboardDateGroupingTests.swift" \
    "$repo_root/tests/ClipboardSearchGeometryTests.swift" \
    "$repo_root/tests/ClipboardHoverSelectionTests.swift" \
    "$repo_root/tests/ClipboardUndoTests.swift" \
    "$repo_root/tests/SingleDeletionUndoTests.swift" \
    "$repo_root/tests/ClipboardTextClassifierTests.swift" \
    "$repo_root/tests/ClipboardPreviewTests.swift" \
    "$repo_root/tests/ImageSearchHighlightTests.swift" \
    "$repo_root/tests/ClipboardPreviewLifecycleTests.swift" \
    "$repo_root/tests/ImageDecodeCoordinatorTests.swift" \
    -o "$test_dir/clipboard-list-tests"
"$test_dir/clipboard-list-tests" "$@"
