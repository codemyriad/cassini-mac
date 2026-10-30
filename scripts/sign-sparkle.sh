#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside the build after embedding and before the app signature is sealed.
set -euo pipefail
framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != YES ]; then exit 0; fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$identity" ]; then identity=-; fi
options=(--options runtime --timestamp)
if [ "$identity" = - ]; then options=(--options runtime --timestamp=none); fi
base="$framework/Versions/B"
# Preserve only the upstream downloader's sandbox profile. Never blanket --deep sign.
codesign --force --sign "$identity" "${options[@]}" --preserve-metadata=entitlements "$base/XPCServices/Downloader.xpc"
for component in XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign --force --sign "$identity" "${options[@]}" "$base/$component"
done
codesign --force --sign "$identity" "${options[@]}" "$framework"
