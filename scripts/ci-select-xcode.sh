#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep Xcode selection job-local: concurrent self-hosted runners share xcode-select.
set -euo pipefail
applications="${CI_XCODE_APPLICATIONS:-/Applications}"
prefer="${CI_XCODE_PREFER:-16.4}"
case "$prefer" in
  16.4) bundles=(Xcode_16.4.app Xcode-27.0.0.app) ;;
  27) bundles=(Xcode-27.0.0.app Xcode_27.0.app Xcode_27.app Xcode_26.6.app Xcode.app) ;;
  *)
    echo "Unsupported CI_XCODE_PREFER value: $prefer" >&2
    exit 1
    ;;
esac
selected=''
for bundle in "${bundles[@]}"; do
  if [[ -d "$applications/$bundle/Contents/Developer" ]]; then
    selected="$applications/$bundle/Contents/Developer"
    break
  fi
done
if [[ -z "$selected" ]]; then
  echo 'Neither supported CI Xcode installation exists' >&2
  exit 1
fi
export DEVELOPER_DIR="$selected"
printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >> "${GITHUB_ENV:?Missing GITHUB_ENV}"
version="$(xcodebuild -version)"
printf '%s\n' "$version"
sdkroot="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT="$sdkroot"
printf 'SDKROOT=%s\n' "$SDKROOT" >> "$GITHUB_ENV"
printf 'SDKROOT=%s\n' "$SDKROOT"
fingerprint="$(printf '%s' "$version" | shasum -a 256 | awk '{print $1}')"
printf 'fingerprint=%s\n' "$fingerprint" >> "${GITHUB_OUTPUT:?Missing GITHUB_OUTPUT}"
# Clang precompiled headers record the absolute module-cache path. Keep only
# content downloads shared across different hosted/self-hosted workspaces.
workspace="$(printf '%s' "${GITHUB_WORKSPACE:-$PWD}" | shasum -a 256 | awk '{print $1}')"
printf 'workspace=%s\n' "$workspace" >> "$GITHUB_OUTPUT"
