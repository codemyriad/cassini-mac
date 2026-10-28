#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
staging="$DERIVED_FILE_DIR/Opus"
python3 "$SRCROOT/scripts/fetch-opus.py" --output "$staging"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Opus"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination" "$frameworks"
library="$frameworks/libopus.0.dylib"
cp "$staging/libopus.0.dylib" "$library"
cp "$staging/LICENSE" "$staging/pins.json" "$destination/"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if [ -z "$identity" ]; then identity=-; fi
    options=(--options runtime --timestamp)
    if [ "$identity" = - ]; then options=(--options 0 --timestamp=none); fi
    codesign --force --sign "$identity" "${options[@]}" "$library"
fi
python3 - "$destination" "$library" <<'PY'
import hashlib,json,sys
from pathlib import Path
folder,library=map(Path,sys.argv[1:])
(folder/'bundle-sha256.json').write_text(json.dumps({library.name:hashlib.sha256(library.read_bytes()).hexdigest()},indent=2)+'\n')
PY
