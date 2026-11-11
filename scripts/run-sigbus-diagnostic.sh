#!/bin/bash
# Diagnostic branch only: no product source changes, no UI/device work.
set -euo pipefail
mkdir -p build/diag
swift build --build-tests --jobs 4 2>&1 | tee build/diag/build.log
export CASSINI_OPUS_ASSETS="$PWD/build/Opus"
export NSUnbufferedIO=YES
python3 scripts/run-swift-tests.py --output build/diag/tests -- \
  swift test --skip-build --disable-swift-testing \
  --skip 'ModelDownloaderTests|ModelSupersessionTests|recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication' \
  2>&1 | tee build/diag/driver.log
