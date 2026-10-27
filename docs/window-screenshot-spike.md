# Whole-window screenshot spike (W1-M3)

This proves the capture mechanism for later design work. It captures the existing
Cassini document window, **not** the new Library design. There are two tests: the
unified-toolbar window alone, and that window with an attached native NSAlert
sheet using HARMONY §7 confirmation 1's exact copy. No recording, playback,
browser connection or hardware audio tests run.

`CassiniScreenshots` is an XcodeGen UI-testing scheme. XCUITest opens the app's
bundled copy of conformance fixture `001-minimal-v1.opus`, identifies the actual
NSWindow, asserts its toolbar, size and sheet controls, then takes
`window.screenshot()`. XCTest retains the PNG attachments. The CI export check
requires both named PNGs, so a skipped suite cannot pass the screenshot gate.

Hidden Debug-only arguments:

```
-CassiniScreenshot window|sheet -CassiniFixture DIR -CassiniNow 2026-10-27T12:00:00Z
```

The fixture directory contains `meeting.opus`. The clock argument is validated;
the current document window has no wall-clock labels to freeze. Screenshot mode
requires the `CASSINI_HOSTED_SCREENSHOTS=1` launch environment. The XCTest suite
skips without that marker. The workflow sets the test-runner marker through
`TEST_RUNNER_CASSINI_HOSTED_SCREENSHOTS` and rejects non-GitHub-hosted runners.
Do not run this UI suite on DrMeyers or the user's desktop.

A local `xcodebuild ... build-for-testing` compiles the app and runner without
launching either. Hosted workflow `ux-shot.yml` runs on `macos-15` with Xcode 16.4.
The primary artifact includes the PNGs, export manifest and test log. Failed
runs also upload the full xcresult bundle as a separate diagnostic artifact.

## Limits and rejected approaches

- A hosting-view `cacheDisplay` cannot include the native titlebar/toolbar or
  attached sheet, so it is not used.
- There is no ScreenCaptureKit capture, screen-recording permission request,
  TCC modification, desktop screen grab or production behavior change.
- The fixture sheet only demonstrates capture. It does not wire the future
  recording-close confirmation to the recorder.
- The bundled fixture avoids an external-file sandbox grant or Open panel.
- The screenshot's point dimensions are 960 × 640; raster dimensions can vary
  with the hosted display's scale. This spike does not claim pixel equivalence
  to the design boards or cross-OS identical native chrome.

API references: [Apple's window screenshot example](https://developer.apple.com/documentation/xcuiautomation/xcuiscreenshot)
and [test runner environment propagation](https://developer.apple.com/videos/play/wwdc2022/110361/).

## Hosted attempt 1

Run [40546900811](https://github.com/codemyriad/cassini-mac/actions/runs/40546900811)
opened both actual document windows and found their toolbars, but failed the
720-point height assertion: the hosted display constrained them to 684/681
points. The failure video also exposed the 1024 × 768 hosted display: the requested
1120-point width extended offscreen. The spike now requests 960 × 640 inside
`NSScreen.visibleFrame`, and asserts every window edge fits on screen. It still
captures the complete window. Future 1120 × 720 board comparisons will need a
larger hosted display mode; this spike does not resize a screenshot to claim a
match.

## Hosted attempt 2

Run [40547290346](https://github.com/codemyriad/cassini-mac/actions/runs/40547290346)
passed both UI tests (including the sheet controls) and exported PNGs. The
artifact verifier rejected Xcode's `_0_<UUID>.png` suffix on attachment names.
The verifier now accepts both plain `.png` and Xcode's suffixed names while
matching each requested attachment separately. The primary artifact excludes
automatic XCTest video files to make PNG inspection quick; failure diagnostics
retain the full xcresult.
