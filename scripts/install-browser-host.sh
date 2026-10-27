#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="--install-extension"
extension_id="${1:-}"
if [[ "$extension_id" == "--uninstall" ]]; then
  mode="--uninstall-extension"
elif [[ ! "$extension_id" =~ ^[a-p]{32}$ ]]; then
  echo "Usage: $0 <32-character extension ID> [Cassini.app] | --uninstall [Cassini.app]" >&2
  exit 1
fi
if [[ -n "${2:-}" ]]; then
  executable="$2/Contents/MacOS/cassini-browser-host"
  [[ -x "$executable" ]] || { echo "The app has no bundled recording host." >&2; exit 1; }
else
  cd "$repo_root"
  swift build -c release --product cassini-browser-host
  if [[ "$mode" == "--uninstall-extension" ]]; then
    executable="$repo_root/.build/release/cassini-browser-host"
  else
    host_dir="$HOME/Library/Application Support/Cassini/BrowserHost"
    mkdir -p "$host_dir"
    chmod 700 "$host_dir"
    cp .build/release/cassini-browser-host "$host_dir/cassini-browser-host"
    chmod 700 "$host_dir/cassini-browser-host"
    codesign --force --sign - "$host_dir/cassini-browser-host"
    executable="$host_dir/cassini-browser-host"
  fi
fi
if [[ "$mode" == "--uninstall-extension" ]]; then
  exec "$executable" "$mode"
else
  exec "$executable" "$mode" "$extension_id"
fi
