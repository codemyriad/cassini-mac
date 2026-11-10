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
if ! executes && [[ "$machine" == arm64 && "$name" == x86_64 ]]; then
  # Several runners share one rented Mac and their Intel jobs start together. Only one of
  # them may run the installer; the others wait for it and then look again.
  lock="${CI_ROSETTA_LOCK:-/tmp/cassini-ci-rosetta-install.lock}"
  waited=0; owned=no
  while ! executes; do
    if mkdir "$lock" 2>/dev/null; then owned=yes; break; fi
    if (( waited == 0 )); then echo 'Another runner is installing Rosetta 2; waiting for it' >&2; fi
    # A lock nobody releases (a killed job) must not hold this one for ever.
    if (( waited >= ${CI_ROSETTA_WAIT:-600} )); then break; fi
    sleep 1; waited=$((waited + 1))
  done
  if [[ "$owned" == yes ]]; then
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT
    if ! executes; then
      echo 'Rosetta 2 is missing on this runner; installing it'
      sudo -n softwareupdate --install-rosetta --agree-to-license || true
    fi
    rmdir "$lock" 2>/dev/null || true
    trap - EXIT
  fi
fi
if ! executes; then
  echo "This $machine runner cannot execute $name products (on Apple Silicon: softwareupdate --install-rosetta --agree-to-license)" >&2
  exit 1
fi
printf 'name=%s\n' "$name" >> "${GITHUB_OUTPUT:?Missing GITHUB_OUTPUT}"
printf 'Products: %s on %s\n' "$name" "$machine"
