#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-app-tests.XXXXXX")
bundle_id="com.eli.Kit.tests.app.$(uuidgen)"
singleton_dir="$HOME/Library/Application Support/$bundle_id"
trap 'rm -rf "$test_dir" "$singleton_dir"' EXIT
build_dir=${KIT_TEST_BUILD_DIR:-"$test_dir/build"}

xcodebuild -quiet -project "$repo_root/Kit.xcodeproj" -scheme Kit \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_dir" \
    CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=YES build

products="$build_dir/Build/Products/Debug"
packages="$build_dir/SourcePackages/checkouts"
ditto "$repo_root/Kit/en.lproj" "$test_dir/en.lproj"
ditto "$repo_root/Kit/zh-Hans.lproj" "$test_dir/zh-Hans.lproj"
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
    "$repo_root/tests/TestSupport.swift" \
    "$repo_root/tests/AppTestSuite.swift" \
    "$repo_root/tests/ClipboardClassifierTests.swift" \
    "$repo_root/tests/WindowGeometryTests.swift" \
    "$repo_root/tests/PasteTransactionTests.swift" \
    "$repo_root/tests/ClipboardStoreIntegrationTests.swift" \
    "$repo_root/tests/FileLifecycleTests.swift" \
    "$repo_root/tests/AppSettingsTests.swift" \
    "$repo_root/tests/SearchSemanticsTests.swift" \
    "$repo_root/tests/PaletteInteractionTests.swift" \
    "$repo_root/tests/CaptureBoundaryTests.swift" \
    "$repo_root/tests/DateGroupingTests.swift" \
    "$repo_root/tests/ImageInfrastructureTests.swift" \
    -o "$test_dir/app-tests"

# Bound deadlocks and hung async tests while preserving the executable exit status
NSUnbufferedIO=YES python3 - "$test_dir/app-tests" "$@" <<'PYCODE'
import os
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], timeout=int(os.environ.get("KIT_TEST_TIMEOUT", "180")))
    sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
except subprocess.TimeoutExpired:
    print("FAIL: app test timeout", flush=True)
    sys.exit(124)
PYCODE
