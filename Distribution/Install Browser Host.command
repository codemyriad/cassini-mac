#!/bin/bash
set -euo pipefail
release_directory="$(cd "$(dirname "$0")" && pwd)"
app_path="$release_directory/Cassini.app"
if [[ ! -d "$app_path" && -d /Applications/Cassini.app ]]; then
  app_path="/Applications/Cassini.app"
fi
if [[ -n "${CASSINI_APP_PATH:-}" ]]; then app_path="$CASSINI_APP_PATH"; fi
executable="$app_path/Contents/MacOS/cassini-browser-host"
if [[ ! -x "$executable" ]]; then
  echo "Keep this installer next to Cassini.app, or move Cassini.app into /Applications." >&2
  exit 1
fi
if [[ "${1:-}" == "--uninstall" ]]; then
  exec "$executable" --uninstall-extension
fi
extension_id="${1:-}"
if [[ -z "$extension_id" ]]; then
  echo "Open chrome://extensions, enable Developer mode, and load the BrowserExtension folder."
  read -r -p "Paste Cassini's extension ID: " extension_id
fi
exec "$executable" --install-extension "$extension_id"
