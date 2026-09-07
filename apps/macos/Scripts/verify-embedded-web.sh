#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
verification_dir=$(mktemp -d)
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library \
  "$package_dir/Sources/MeetingAgentApp/EmbeddedWebView.swift" \
  "$package_dir/Verification/EmbeddedWebViewCheck.swift" \
  -o "$verification_dir/EmbeddedWebViewCheck"
"$verification_dir/EmbeddedWebViewCheck" "$@"
