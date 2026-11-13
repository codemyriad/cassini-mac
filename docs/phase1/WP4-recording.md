# WP4 Recording (big-mac)

Implements L-20/L-47/L-48 against Build-WP4 and Recording-Mac light/dark/silent boards. Built on WP3 after Foundations #290 merged. One main-based WP4 draft PR, Seat: big-mac, with exact-head CI and actual light/dark pr-shots before ready.

Recording stays beside the Library. The page owns its title/pencil and a date without a repeated duration or Since line. Native captures use the producer's known start; other recordings use the shared D95 meeting-time formatter, preserving civil labels/unknown dates. The compact timer uses30pt system type and a soft-ring dot; Stop is30pt and invokes the same capture owner. Saving disables it. Title editing uses the existing model, immediate producer title update, debounce/flush and metadata-readonly guards. No recording schema/clock/PCM/protocol changes.

One12pt sources card keeps current spectrograms, microphone silence/Check, source descriptions, Change what is recorded and its existing eligibility. At narrow window widths, meters move below their labels and the timer/Stop row can stack while retaining30pt sizing; a real generated-input UI case resizes the window and stops the recording. Source rows omit decorative icons; the Change row has a microphone and chevron. Recording details is in More, with the same report sheet. Disk, permission, fallback and source-problem lines/actions remain. The retained toolbar live pill preserves hidden recording/global-shortcut controls; sidebar Search/Import styling remains WP2's responsibility.

Hosted fixtures capture normal and silent microphone states separately; they consume the same bounded pinned PCM through the existing spectrogram transform and never open devices. Recording-silent is added to required light/dark exports, both screenshot-tool test inventories and the existing explicit dark recording case. Real UI assertions check date/title, sidebar, source actions,30pt Stop, details access, live title edits, hidden recording state and saved notification. Title editing now opens from the pencil rather than an always-visible field. No summaries, notes backend, saved voices or Phase2 work.

Verification: targeted swift test --filter only (MeetingTimeTests, MeetingTimeR2LibraryTests, D61ClockFactsTests, SpectrogramFixtureClockTests, D69StoppedWarningTests); native app/UI test build through heavy-run with Xcode16.4/macOS SDK15.5; copy/token and CI contract checks,2exporter and10Pillow comparison tests. Actual runtime/screenshot results must be recorded separately; compilation is not a UI-pass claim. No local app/GUI/audio/device launches while runners are active.

## Review follow-up

The live detail uses the persistent sidebar Import header and its trailing
alignment, including frozen screenshots. Unowned live captures remain live,
while Saving keeps the same detail owner. Opening a Library recording synchronizes
selection; Back to Library is available for Search and external-file contexts.
A discarded blank capture closes only when it disappears from a successful scan.

Source rows switch at an actual card-width threshold, so desktop warnings wrap
beside their meter and Check. Healthy meters use the trailing padding without an
empty Check column. Narrow meters align leading. Check uses the card-stroke token.

The title popover keeps a draft until confirmation/dismissal; Escape cancels it.
Scanner titles update clean editors, pending local edits survive scans, and
clearing a browser title removes the live override instead of publishing Untitled.
Native probes cover these title transitions, sidebar selection, retained Saving
ownership and discarded captures. Hosted UI checks cover header geometry, source
row geometry, Escape, narrow actions and real Stop. Shared Find fixes live in the
WP3 parent, with required native cache proofs. Keep this PR draft until WP3 merges
and current-head CI plus actual screenshot publication pass.
