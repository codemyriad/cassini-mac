#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--uninstall" ]]; then
  python3 "$repo_root/scripts/register-browser-host.py" --uninstall
  exit
fi
extension_id="${1:-}"
if [[ ! "$extension_id" =~ ^[a-p]{32}$ ]]; then
  echo "Usage: $0 <32-character extension ID> [Cassini.app] | --uninstall" >&2
  exit 1
fi
if [[ -n "${2:-}" ]]; then
  executable="$2/Contents/MacOS/cassini-browser-host"
  [[ -x "$executable" ]] || { echo "The app has no bundled recording host." >&2; exit 1; }
else
  cd "$repo_root"
  swift build -c release --product cassini-browser-host
  host_dir="$HOME/Library/Application Support/Cassini/BrowserHost"
  mkdir -p "$host_dir"
  chmod 700 "$host_dir"
  cp .build/release/cassini-browser-host "$host_dir/cassini-browser-host"
  chmod 700 "$host_dir/cassini-browser-host"
  codesign --force --sign - "$host_dir/cassini-browser-host"
  executable="$host_dir/cassini-browser-host"
fi
python3 "$repo_root/scripts/register-browser-host.py" "$extension_id" "$executable"
