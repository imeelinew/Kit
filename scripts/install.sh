#!/bin/zsh
set -euo pipefail

# Build a Release copy of Kit and install it into /Applications for daily use.
# Quits any running instance first, launches the installed copy at the end.

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_name="Kit"
installed_app="/Applications/${app_name}.app"

cd "$repo_root"

if pgrep -xq "$app_name"; then
    print "Quitting $app_name"
    osascript -e "tell application \"$app_name\" to quit" >/dev/null || true
    for _ in {1..20}; do
        pgrep -xq "$app_name" || break
        sleep 0.5
    done
    if pgrep -xq "$app_name"; then
        print -u2 "$app_name did not quit; force killing"
        killall "$app_name"
        sleep 1
    fi
fi

print "Building Release"
xcodebuild \
    -project Kit.xcodeproj \
    -scheme Kit \
    -configuration Release \
    build

built_app=$(xcodebuild -project Kit.xcodeproj -scheme Kit -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/${app_name}.app
[[ -d "$built_app" ]] || {
    print -u2 "Built app not found: $built_app"
    exit 70
}

print "Installing to $installed_app"
rm -rf "$installed_app"
ditto "$built_app" "$installed_app"

print "Launching $app_name"
open "$installed_app"
