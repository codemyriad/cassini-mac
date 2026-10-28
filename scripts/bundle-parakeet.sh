#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
staging="$DERIVED_FILE_DIR/Parakeet"
if [ -n "${CASSINI_CI_ASSETS:-}" ]; then
    python3 "$SRCROOT/scripts/ci-products.py" stage-assets Parakeet "$staging"
else
    python3 "$SRCROOT/scripts/fetch-parakeet-runtime.py" --output "$staging"
fi
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Parakeet"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
worker="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/cassini-parakeet-worker"
mkdir -p "$resources" "$frameworks"
for name in pins.json UPSTREAM.json Sherpa-LICENSE ONNXRuntime-LICENSE ONNXRuntime-ThirdPartyNotices.txt model-manifest.json; do cp "$staging/$name" "$resources/$name"; done
for name in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do cp "$staging/$name" "$frameworks/$name"; done
cp "$BUILT_PRODUCTS_DIR/cassini-parakeet-worker" "$worker"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"; if [ -z "$identity" ]; then identity=-; fi
    options=(--options runtime --timestamp)
    if [ "$identity" = - ]; then options=(--options 0 --timestamp=none); fi
    for name in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do codesign --force --sign "$identity" "${options[@]}" "$frameworks/$name"; done
    codesign --force --sign "$identity" "${options[@]}" --entitlements "$SRCROOT/Whistle/worker.entitlements" "$worker"
fi
python3 - "$resources" "$worker" "$frameworks" <<'PY'
import hashlib,json,sys
from pathlib import Path
resources,worker,frameworks=map(Path,sys.argv[1:])
files=[worker,frameworks/'libsherpa-onnx-c-api.dylib',frameworks/'libonnxruntime.dylib']
(resources/'bundle-sha256.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
PY
