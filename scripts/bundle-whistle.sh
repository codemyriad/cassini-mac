#!/bin/bash
set -euo pipefail
# Xcode build step. No downloading happens in Cassini or the worker at runtime.
staging="$DERIVED_FILE_DIR/Whistle"
python3 "$SRCROOT/scripts/fetch-whistle.py" --output "$staging"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Whistle"
mkdir -p "$destination"
cp "$staging/"* "$destination/"
if [ "$CONFIGURATION" = Debug ]; then
    cp "$SRCROOT/Tests/CassiniWhistleTests/Fixtures/jfk.wav" "$destination/jfk.wav"
    cp "$SRCROOT/Tests/CassiniWhistleTests/Fixtures/jfk.txt" "$destination/jfk.txt"
fi
worker="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/cassini-whistle-worker"
cp "$BUILT_PRODUCTS_DIR/cassini-whistle-worker" "$worker"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if [ -z "$identity" ]; then identity=-; fi
    codesign --force --sign "$identity" --options runtime --timestamp=none "$destination/libneedle3.dylib"
    codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements "$SRCROOT/Whistle/worker.entitlements" "$worker"
fi
# Record what is actually shipped, including signatures, separately from source pins.
python3 - "$destination" "$worker" <<'PY'
import hashlib,json,sys
from pathlib import Path
folder, worker = map(Path, sys.argv[1:])
def sha(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): value.update(block)
    return value.hexdigest()
(folder/'bundle-sha256.json').write_text(json.dumps({p.name:sha(p) for p in [folder/'libneedle3.dylib',folder/'whistle.cact',worker]},indent=2)+'\n')
PY
