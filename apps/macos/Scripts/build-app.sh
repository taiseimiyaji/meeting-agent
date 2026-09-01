#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
configuration=${CONFIGURATION:-debug}
repository_dir=$(dirname "$package_dir")
repository_dir=$(dirname "$repository_dir")
web_dir="$repository_dir/apps/web"
output_dir="$package_dir/.build/app"
app_dir="$output_dir/MeetingAgent.app"

cd "$package_dir"
swift build --disable-sandbox -c "$configuration" --product MeetingAgent
bin_dir=$(swift build --disable-sandbox -c "$configuration" --show-bin-path)

if [ ! -d "$web_dir/node_modules" ]; then
  (cd "$web_dir" && npm ci)
fi
(cd "$web_dir" && npm run build)

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/MeetingAgent" "$app_dir/Contents/MacOS/MeetingAgent"
rm -rf "$app_dir/Contents/Resources/Web"
cp -R "$web_dir/dist" "$app_dir/Contents/Resources/Web"

codesign --force --sign - --entitlements "$package_dir/Resources/MeetingAgent.entitlements" "$app_dir"
echo "$app_dir"
