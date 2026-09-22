#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"
project_file="${0:A:h:h}/Kit.xcodeproj/project.pbxproj"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Invalid marketing version: $version"
    exit 64
fi
if [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Build number must be a positive integer: $build"
    exit 64
fi

ruby - "$project_file" "$version" "$build" <<'RUBY'
path, version, build = ARGV
contents = File.binread(path)
marketing_count = contents.scan(/MARKETING_VERSION = [^;]+;/).length
build_count = contents.scan(/CURRENT_PROJECT_VERSION = [^;]+;/).length
abort "Unexpected MARKETING_VERSION entry count: #{marketing_count}" unless marketing_count == 4
abort "Unexpected CURRENT_PROJECT_VERSION entry count: #{build_count}" unless build_count == 4
contents.gsub!(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = #{version};")
contents.gsub!(/CURRENT_PROJECT_VERSION = [^;]+;/, "CURRENT_PROJECT_VERSION = #{build};")
File.binwrite(path, contents)
RUBY

print "Kit version set to ${version} (${build})"
