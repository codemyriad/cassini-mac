# WP7 Imported (L-57)

Implements desktop L-57 using merged cassini-ux #19 at
`a08ee0aff82d58448b42d9799747088ae01ce1ea`. Imported labels come from the
shared catalog; internal `received` kinds and folder names stay unchanged.
The persistent folder banner is replaced by a dismissible first-open toast.
The folder glyph, Close action, inverse pill and shadow use existing
CassiniTokens roles. No English fallback or local shared label is introduced.

`transcriptFromImportedFile` is a transient scanner fact. Only a readable,
completed, validated embedded transcript supplies it. Plain audio, local sidecar
replacements, incomplete jobs and unverified content cannot claim another-device
words. No new manifest or meeting.json field is written.
Valid read-only external documents retain that transcript attribution too;
they remain ineligible for a toast claiming that a Library copy exists.

`ImportedMeetingNotice` prepares a candidate without consuming its appearance.
Only the rendered notice's acknowledgement persists a seen flag, keyed by the
stable meeting UUID in existing app preferences. Repeated updates keep a shown
receipt visible; dismissal, navigation or loss of visibility clears it. Late
appearance/dismiss callbacks for another meeting cannot consume or clear the
current receipt. The flag survives controller recreation and Library moves.

The Library adapter reads actual application, key-window and sheet state through
a weak window reference and native notifications. It also defers while a SwiftUI sheet is requested but not yet attached. It accepts only saved, copied
Library imports with available audio and received metadata. External documents,
unavailable Library content, moves and hidden panes are ineligible. Appearance
reconciles current selection before consuming a candidate. No timing-driven
startup delay or new storage schema is introduced.

The headless check compiles the production state owner directly with the Swift
probe, opens no app or windows, and uses an isolated preference suite. It covers
inactive app/window state, sheets arriving before appearance, hidden content,
stale callbacks, independent meetings and persisted seen state. CI runs it in
the boards job, and policy/probe-only changes select that consumer.

Run `~/bin/heavy-run python3 -I scripts/test-imported-notice-state.py` with the
selected Xcode toolchain. Native app/UI compilation uses Xcode 16.4 and SDK 15.5.
Actual UI execution and screenshots remain hosted-only.

Header and compact-header subtitles use the full shared template. Only a trusted
completed transcript carried by the imported file adds the other-device phrase.
A later local sidecar removes that attribution. Unknown dates remain unknown;
unzoned civil labels retain their written clock. D95 reader, sorting and export
semantics are unchanged. The existing D81 Alex onboarding fixture changes are
preserved alongside the new upstream badge expectations.

The received UI case captures both first-open and normal states in light/dark,
then relaunches with the same isolated preferences. It waits for a read-only
DEBUG evaluation observation before asserting that the toast stays absent, so
startup timing cannot pass that check vacuously. A real native Open-panel import from an
unrepresentable parent name tests the shared no-folder fallback, including the
Powerbox grant for the runner-created file outside the app sandbox. Duplicate Finder
opens keep one viewer and do not restore the retired banner. No fixed sleep is
used for notice success. Export requires all 35 light/dark pairs.

This package remains draft while parent packages or exact-head CI are pending.
Before readiness publish actual before/after screenshots and inspect both modes.
