#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-memory-profile.XXXXXX")
probe_id="com.eli.Kit.memory-probe.${test_dir:t}"
support_dir="$HOME/Library/Application Support/$probe_id"
prefs_file="$HOME/Library/Preferences/$probe_id.plist"
trap 'rm -rf "$test_dir" "$support_dir"; rm -f "$prefs_file"' EXIT
build_dir=${KIT_PROFILE_BUILD_DIR:-"$test_dir/build"}

if [[ ${KIT_PROFILE_SKIP_BUILD:-0} != 1 ]]; then
    xcodebuild -quiet -project "$repo_root/Kit.xcodeproj" -scheme Kit \
        -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build_dir" \
        CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=YES build
fi

products="$build_dir/Build/Products/Debug"
packages=${KIT_PROFILE_PACKAGES_DIR:-"$build_dir/SourcePackages/checkouts"}
probe_app="$test_dir/MemoryProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
ditto "$products/Kit.app/Contents/Resources" "$probe_app/Contents/Resources"
cat > "$probe_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$probe_id</string>
<key>CFBundleExecutable</key><string>clipboard-memory-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
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
    "$repo_root/tests/ClipboardMemoryProbe.swift" \
    -o "$probe_app/Contents/MacOS/clipboard-memory-probe"
"$probe_app/Contents/MacOS/clipboard-memory-probe"
