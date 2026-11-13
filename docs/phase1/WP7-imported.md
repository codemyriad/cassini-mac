# WP7 Imported (L-57)

Preparation is stacked after WP6. The shared visible copy and pin still await
cassini-ux #19; this stage does not rename badges or render the toast.

`transcriptFromImportedFile` is a transient scanner fact. Only a readable,
completed, validated embedded transcript supplies it. Plain audio, local sidecar
replacements, incomplete jobs and unverified content cannot claim another-device
words. No new manifest or meeting.json field is written.

`ImportedMeetingNotice` prepares a candidate without consuming its appearance.
Only the rendered notice's acknowledgement persists a seen flag, keyed by the
stable meeting UUID in existing app preferences. Repeated updates keep a shown
receipt visible; dismissal, navigation or loss of visibility clears it. Late
appearance/dismiss callbacks for another meeting cannot consume or clear the
current receipt. The flag survives controller recreation and Library moves.

The Library adapter reads actual application, key-window and sheet state through
a weak window reference and native notifications. It accepts only saved, copied
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
