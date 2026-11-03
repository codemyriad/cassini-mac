# Known CI flakes (D66)

No blanket retries (D66 rule 2): a flake stays visible, and is either fixed at its
root or tracked here with what diagnoses it.

## Browser return: "Same Chromium transport did not restore after navigation"

- Where: UX browser setup, step "Real Chromium navigation and app-owned source
  restoration" (`scripts/test-browser-return.mjs`, `BrowserReturnSelfTest`), both
  runners. 14 jobs in 5 days (2 on main) as of 2026-11-03, still recurring.
- Signature: browserAlive=false, transportAlive=false, usingSystem=true,
  page=present, about 34 s after lostUptime: after the reload Chromium never
  re-attached the original transport within the 35 s bound.
- Status: tracked, not retried; the bound is not raised. Since mac-P0-1 a failure
  also records the extension's native connects and disconnects (with
  `lastError`), its worker errors, and every service-worker start and close, in
  the job log and `build/browser-return-report.json.extension.json`. They are
  streamed into Node as they happen (`scripts/extension-native-log.mjs`), so a
  worker that closed first loses nothing; `scripts/test-extension-native-log.mjs`
  (kit) proves it. The extension
  is vendored from cassini-browser-protocol; a reload race there was reported to
  its owners.
- Not this flake: "Navigation did not start computer-sound fallback" (8 jobs,
  10-31 to 11-02) was a product bug, fixed by 50e4be2 (#101); it has not recurred.

## Settings resume proof: EPERM removing the destination

- See mac-P0-3 (#124): intermittent POSIX EPERM on `CassiniSettingsDestination-*`;
  20 lab repetitions did not reproduce it. A failure now records the remaining
  entries, sandbox denials and live processes.
