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
The artifact includes the PNGs, export manifest, test log and xcresult bundle.

## Limits and rejected approaches

- A hosting-view `cacheDisplay` cannot include the native titlebar/toolbar or
  attached sheet, so it is not used.
- There is no ScreenCaptureKit capture, screen-recording permission request,
  TCC modification, desktop screen grab or production behavior change.
- The fixture sheet only demonstrates capture. It does not wire the future
  recording-close confirmation to the recorder.
- The bundled fixture avoids an external-file sandbox grant or Open panel.
- The screenshot's point dimensions are 1120 × 720; raster dimensions can vary
  with the hosted display's scale. This spike does not claim pixel equivalence
  to the design boards or cross-OS identical native chrome.

API references: [Apple's window screenshot example](https://developer.apple.com/documentation/xcuiautomation/xcuiscreenshot)
and [test runner environment propagation](https://developer.apple.com/videos/play/wwdc2022/110361/).

Hosted results and any failed attempts are recorded below after the first run.
