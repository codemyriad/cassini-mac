#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Name the architecture of the SwiftPM products this job restores and prove the
# machine can execute it before any product is downloaded.
set -euo pipefail
machine="$(uname -m)"
name="${CASSINI_CI_ARCH:-$machine}"
case "$name" in
  arm64|x86_64) ;;
  *) echo "Unsupported CASSINI_CI_ARCH: $name" >&2; exit 1 ;;
esac
executes() { [[ "$(arch "-$name" /usr/bin/uname -m 2>/dev/null)" == "$name" ]]; }
if ! executes; then
  if [[ "$machine" == arm64 && "$name" == x86_64 ]]; then
    echo 'Rosetta 2 is missing on this runner; installing it'
    sudo -n softwareupdate --install-rosetta --agree-to-license || true
  fi
  if ! executes; then
    echo "This $machine runner cannot execute $name products (on Apple Silicon: softwareupdate --install-rosetta --agree-to-license)" >&2
    exit 1
  fi
fi
printf 'name=%s\n' "$name" >> "${GITHUB_OUTPUT:?Missing GITHUB_OUTPUT}"
printf 'Products: %s on %s\n' "$name" "$machine"
