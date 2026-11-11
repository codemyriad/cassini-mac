# Validation receipt

Base: `89c568bca3528417a74888720f0379103273138d` (#210 merged; ordinary merge of current main)

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

`current-main-receipt.json` records source hashes matching the restored private
scratch and the intended assertion from each of seven fresh mutation logs.
The baseline EOF-to-timeout mutant still passes the old assertion on this base.
One combined compilation/test guard expired before the seventh test started;
that attempt was not counted. Replay now builds with a separate 180-second
failure guard and runs tests with a 45-second failure guard. All seven cases
then compiled, failed their intended assertions and restored 25 tests passed.
No success depends on those bounds.
