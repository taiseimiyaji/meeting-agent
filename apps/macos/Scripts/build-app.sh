#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
configuration=${CONFIGURATION:-debug}
output_dir="$package_dir/.build/app"
app_dir="$output_dir/MeetingAgent.app"

cd "$package_dir"
swift build -c "$configuration" --product MeetingAgent
bin_dir=$(swift build -c "$configuration" --show-bin-path)

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/MeetingAgent" "$app_dir/Contents/MacOS/MeetingAgent"

codesign --force --sign - --entitlements "$package_dir/Resources/MeetingAgent.entitlements" "$app_dir"
echo "$app_dir"
