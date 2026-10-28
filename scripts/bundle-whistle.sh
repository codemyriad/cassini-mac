#!/bin/bash
set -euo pipefail
# Xcode build step. No downloading happens in Cassini or the worker at runtime.
staging="$DERIVED_FILE_DIR/Whistle"
python3 "$SRCROOT/scripts/fetch-whistle.py" --output "$staging"
python3 "$SRCROOT/scripts/fetch-vad.py" --output "$staging"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Whistle"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination" "$frameworks"
for resource in whistle.cact LICENSE NOTICE pins.json silero_vad.onnx Silero-LICENSE ONNXRuntime-LICENSE ONNXRuntime-ThirdPartyNotices.txt; do cp "$staging/$resource" "$destination/$resource"; done
library="$frameworks/libneedle3.dylib"
cp "$staging/libneedle3.dylib" "$library"
vadlibrary="$frameworks/libonnxruntime.1.23.2.dylib"
cp "$staging/libonnxruntime.1.23.2.dylib" "$vadlibrary"
# Remove only obsolete generated copies from incremental builds of the old layout.
rm -f "$destination/libneedle3.dylib" "$destination/unsigned-sha256.json"
rm -f "${destination%/Whistle}/cassini-whistle-worker" "${destination%/Whistle}/cassini-browser-host"
if [ "$CONFIGURATION" = Debug ]; then
    cp "$SRCROOT/Tests/CassiniWhistleTests/Fixtures/jfk.wav" "$destination/jfk.wav"
    cp "$SRCROOT/Tests/CassiniWhistleTests/Fixtures/jfk.txt" "$destination/jfk.txt"
fi
worker="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/cassini-whistle-worker"
cp "$BUILT_PRODUCTS_DIR/cassini-whistle-worker" "$worker"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if [ -z "$identity" ]; then identity=-; fi
    timestamp=(--timestamp)
    options=(--options runtime)
    # Ad-hoc signatures have no Team ID. Runtime library validation rejects
    # loading the bundled ad-hoc engine on current macOS; match Xcode's own
    # ad-hoc behavior. Real identities retain runtime and same-team validation.
    if [ "$identity" = - ]; then timestamp=(--timestamp=none); options=(--options 0); fi
    codesign --force --sign "$identity" "${options[@]}" "${timestamp[@]}" "$library"
    codesign --force --sign "$identity" "${options[@]}" "${timestamp[@]}" "$vadlibrary"
    codesign --force --sign "$identity" "${options[@]}" "${timestamp[@]}" --entitlements "$SRCROOT/Whistle/worker.entitlements" "$worker"
fi
# Record what is actually shipped, including signatures, separately from source pins.
python3 - "$destination" "$worker" "$library" "$vadlibrary" <<'PY'
import hashlib,json,sys
from pathlib import Path
folder, worker, library, vadlibrary = map(Path, sys.argv[1:])
def sha(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): value.update(block)
    return value.hexdigest()
(folder/'bundle-sha256.json').write_text(json.dumps({p.name:sha(p) for p in [library,vadlibrary,folder/'silero_vad.onnx',folder/'whistle.cact',worker]},indent=2)+'\n')
PY
