#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
case "${1:-}" in
  ""|--sink-only) ;;
  *) echo "Usage: $0 [--sink-only]" >&2; exit 2 ;;
esac
check_dir="$(mktemp -d /tmp/cassini-native-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
xcodegen generate
if ! xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Debug -derivedDataPath build build > "$check_dir/build.log" 2>&1; then
  cat "$check_dir/build.log"
  exit 1
fi
if [[ "${1:-}" == "--sink-only" ]]; then
  build/Build/Products/Debug/Cassini.app/Contents/MacOS/Cassini --recording-sink-self-test > "$check_dir/output.log" 2> "$check_dir/error.log"
else
  echo 'Testing only generated audio. Allow Cassini system-audio access if macOS prompts.'
# LaunchServices attributes privacy access to Cassini, unlike a direct binary launch from SSH.
open -n -W --stdout "$check_dir/output.log" --stderr "$check_dir/error.log" \
  build/Build/Products/Debug/Cassini.app --args --recording-self-test
fi
cat "$check_dir/output.log"
if ! rg -q '^RECORDING_SELF_TEST_PASSED$' "$check_dir/output.log"; then
  cat "$check_dir/error.log"
  exit 1
fi
