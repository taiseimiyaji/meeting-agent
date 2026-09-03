#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
bundle_id=dev.meeting-agent.macos

reset_permissions=false
if [ "${1:-}" = "--reset-permissions" ]; then
  reset_permissions=true
elif [ -n "${1:-}" ]; then
  echo "usage: sh Scripts/dev.sh [--reset-permissions]" >&2
  exit 2
fi

# Never replace the executable while the previous instance is running.
pkill -x MeetingAgent 2>/dev/null || true

sh "$script_dir/build-app.sh"
app="$package_dir/.build/app/MeetingAgent.app"

if codesign -dvv "$app" 2>&1 | grep -q '^Signature=adhoc$'; then
  reset_permissions=true
  echo "Ad-hoc development build detected; permissions will be requested again."
fi

if [ "$reset_permissions" = true ]; then
  echo "Resetting development permissions for $bundle_id"
  tccutil reset ScreenCapture "$bundle_id" || true
  tccutil reset Microphone "$bundle_id" || true
  tccutil reset SpeechRecognition "$bundle_id" || true
fi

echo "Launching $app"
open "$app"
