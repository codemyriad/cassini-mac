#!/bin/bash
# Mirrors the macos-15-intel consumer steps of ci.yml package_tests and ux-whistle.yml worker.
# usage: intel-steps.sh <repo> <logdir> [prefix...]   (prefix e.g. "arch -x86_64")
repo="$1"; logs="$2"; shift 2; X=("$@")
cd "$repo" || exit 2
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export PATH=/opt/homebrew/bin:$PATH
export NEEDLE_TELEMETRY=0 DO_NOT_TRACK=1 ORT_DISABLE_TELEMETRY=1
W="$PWD"
step(){ name="$1"; shift; s=$(date +%s); "$@" > "$logs/$name.log" 2>&1; rc=$?; printf '%-28s rc=%s secs=%s\n' "$name" "$rc" "$(( $(date +%s)-s ))"; }
step pkg-downloader env CASSINI_FIXTURE_DIAGNOSTICS=$W/build/model-bootstrap CASSINI_FIXTURE_BOOTSTRAP_LIMIT=2 "${X[@]}" swift test --skip-build --filter ModelDownloaderTests
step pkg-exports env CASSINI_OPUS_ASSETS=$W/build/Opus CASSINI_EXPORT_REPORT_DIR=$W/build/export-cases "${X[@]}" swift test --skip-build --filter 'ExportGoldenTests|MeetingExportTests|ExportDestinationTests|PortableWriterTests|OpusTests|LibraryImport|R65CodemyriadNamespaceTests'
step pkg-export-reference "${X[@]}" python3 scripts/check-export-reference.py "$HOME/work/cassini-format" build/export-cases
step wh-regressions "${X[@]}" swift test --skip-build --filter Whistle
step wh-fetch-cache "${X[@]}" python3 scripts/test-whistle-fetch.py
step wh-asset-integration env CASSINI_WHISTLE_TEST_ASSETS=$W/build/Whistle "${X[@]}" swift test --skip-build --filter WhistleAssetIntegrationTests
step wh-pipeline-goldens env CASSINI_PIPELINE_ASSETS=$W/build/Whistle CASSINI_PIPELINE_REPORT_DIR=$W/build/pipeline "${X[@]}" swift test --skip-build --filter 'PipelineTests|TranscriptionMeetingTests'
step wh-worker-jfk "${X[@]}" python3 scripts/test-whistle-worker.py --worker .build/debug/cassini-whistle-worker --bundle build/Whistle --report build/whistle-intel.json
