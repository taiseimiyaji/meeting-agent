#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
configuration=${CONFIGURATION:-debug}
repository_dir=$(dirname "$package_dir")
repository_dir=$(dirname "$repository_dir")
web_dir="$repository_dir/apps/web"
output_dir=${APP_OUTPUT_DIR:-"$package_dir/.build/app"}
app_dir="$output_dir/MeetingAgent.app"

# Replacing a running signed executable invalidates its entitlement lookup.
# Check before building as well as immediately before installing the bundle.
ensure_not_running() {
  if ps -ww -axo comm= | awk -v executable="$app_dir/Contents/MacOS/MeetingAgent" '$0 == executable { found = 1 } END { exit !found }'; then
    echo "Meeting Agent is running from $app_dir. Quit it before rebuilding, or set APP_OUTPUT_DIR to stage a separate build." >&2
    exit 1
  fi
}
ensure_not_running

cd "$package_dir"
swift build --disable-sandbox -c "$configuration" --product MeetingAgent
swift build --disable-sandbox -c "$configuration" --product MeetingCodexHelper
bin_dir=$(swift build --disable-sandbox -c "$configuration" --show-bin-path)

if [ ! -d "$web_dir/node_modules" ]; then
  (cd "$web_dir" && npm ci)
fi
(cd "$web_dir" && npm run build)

ensure_not_running
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/MeetingAgent" "$app_dir/Contents/MacOS/MeetingAgent"
for resource_bundle in "$bin_dir"/*.bundle; do
  [ -d "$resource_bundle" ] || continue
  resource_name=$(basename "$resource_bundle")
  rm -rf "$app_dir/Contents/Resources/$resource_name"
  cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
done
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

helper_dir="$app_dir/Contents/Helpers/MeetingCodexHelper.app"
mkdir -p "$helper_dir/Contents/MacOS"
cp "$bin_dir/MeetingCodexHelper" "$helper_dir/Contents/MacOS/MeetingCodexHelper"
cp "$package_dir/Resources/CodexHelper-Info.plist" "$helper_dir/Contents/Info.plist"
# LaunchServices starts this companion independently of the capture sandbox.
# It owns no credentials: only the installed Codex CLI accesses its login.
codesign --force --sign "$signing_identity" "$helper_dir"
codesign --force --sign "$signing_identity" --entitlements "$package_dir/Resources/MeetingAgent.entitlements" "$app_dir"
echo "Meeting Agent is ready: $app_dir"
