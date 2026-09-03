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

signing_identity=${CODE_SIGN_IDENTITY:-}
if [ -z "$signing_identity" ]; then
  signing_identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/{print $2; exit}')
fi
if [ -z "$signing_identity" ]; then
  signing_identity=-
  echo "warning: Apple Development certificate not found; using ad-hoc signing." >&2
  echo "warning: macOS may require a TCC permission reset after rebuilding." >&2
else
  echo "Signing with stable identity: $signing_identity"
fi

codesign --force --sign "$signing_identity" --entitlements "$package_dir/Resources/MeetingAgent.entitlements" "$app_dir"
echo "Meeting Agent is ready: $app_dir"
