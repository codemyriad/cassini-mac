# Validation receipt

Base: `555759db49f2800e6e70605b6176a0fb6c452d52`

Xcode 16.4; explicit macOS 15.5 SDK; arm64; heavy-run.

Before: 25 XCTest cases passed.
After: 25 XCTest cases passed.
Restored: 25 XCTest cases passed.

The baseline EOF-to-timeout mutant passed the old assertion.
All seven revised mutants compiled, ran their selected test, and failed:

- `stale-peer-output` / `testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection`: XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `reconnect-stop-output` / `testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart`: XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `audio-stop-all-output` / `testRegisteredAudioThenDisconnectedStopAllBeforeAnyCaptureStatusCannotRestart`: XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `held-start-output` / `testTheServiceCompletesALostStartOnceWhenTheRestartedLinkReportsTheCapture`: XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `legacy-initial-output` / `testALegacyHelloIsNeverPingedOrTimedOut`: XCTAssertEqual failed: ("Optional("ping")") is not equal to ("Optional("command")") - A legacy peer must receive no heartbeat before the requested command
- `legacy-frame-output` / `testALegacyHelloIsNeverPingedOrTimedOut`: XCTAssertEqual failed: ("Optional("ping")") is not equal to ("Optional("command")") - A legacy peer must receive no heartbeat before the requested command
- `lost-peer-eof` / `testPingsOverTheRealPipeAndSilenceLosesControl`: XCTAssertNil failed: threw error "timeout" - The lost connection must close; a receive timeout fails

Apply one mutant at a time with `git apply --unidiff-zero <name>.patch`.
Run the named test with `swift test --jobs 4 --filter <test>`, then reverse the patch before the next case.

A discarded legacy Start fixture failed because the original legacy capabilities do not support Start. The final fixture observes a recording status and requests Stop.
One replay hit a Swift Foundation deserialization crash after changing the scratch path alias. Reusing the baseline path completed the entire after/mutation/restored run. Both discarded logs remain with the full external evidence.
