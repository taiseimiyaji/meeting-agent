#!/bin/sh
set -eu
# Default: read-only login/quota check. --summarize uses the user's Codex allowance
# for a synthetic four-image meeting; never reads real meeting data.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
check_app="$package_dir/.build/codex-validation/MeetingCodexCheck.app"
report="$HOME/Library/Containers/dev.meeting-agent.codex-validation/Data/Library/Application Support/MeetingCodexVerification.txt"
if ps -ww -axo comm= | awk -v executable="$check_app/Contents/MacOS/MeetingVerification" '$0 == executable { found = 1 } END { exit !found }'; then
  echo "Codex verification is already running." >&2
  exit 1
fi
swift build --package-path "$package_dir" --product MeetingVerification
swift build --package-path "$package_dir" --product MeetingCodexHelper
bin_dir=$(swift build --package-path "$package_dir" --show-bin-path)
helper="$check_app/Contents/Helpers/MeetingCodexHelper.app"
mkdir -p "$check_app/Contents/MacOS" "$helper/Contents/MacOS"
cp "$bin_dir/MeetingVerification" "$check_app/Contents/MacOS/MeetingVerification"
cp "$bin_dir/MeetingCodexHelper" "$helper/Contents/MacOS/MeetingCodexHelper"
cp "$package_dir/Resources/CodexHelper-Info.plist" "$helper/Contents/Info.plist"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.meeting-agent.codex-validation</string>
<key>CFBundleExecutable</key><string>MeetingVerification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$helper"
codesign --force --sign - --entitlements "$package_dir/Resources/MeetingAgent.entitlements" "$check_app"
rm -f "$report"
open -n "$check_app" --args codex-live "$@"
attempt=0
while [ "$attempt" -lt 330 ]; do
  if [ -f "$report" ]; then
    cat "$report"
    rg -q '^PASS:' "$report"
    exit $?
  fi
  attempt=$((attempt + 1))
  sleep 1
done
echo "Verification timed out. No success report was produced." >&2
exit 1
