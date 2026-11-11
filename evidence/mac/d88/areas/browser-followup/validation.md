# Validation receipt

Base main: `89c568bca3528417a74888720f0379103273138d`; reviewed head: `4b5feff15aa3d4ab61e006d5dbda83604ccbf1d7`.
Xcode 16.4, explicit macOS SDK, arm64, heavy-run.

Before / after / restored: **25 XCTest cases pass** each.
The EOF-to-timeout mutation passes the original test.
The real late status-renegotiation mutation passes the reviewed legacy test,
then fails the corrected test after it ticks the manual clock after frames.

Eight production mutations compile and fail behavioral assertions; no
expectation timeout is accepted. The former synthetic send injections are
superseded and are not counted as proof.

- `stale-peer-output`: CassiniBrowserControlTests/ControlServiceTests.swift:232: error: -[CassiniBrowserControlTests.ControlServiceTests testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection] : XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `reconnect-stop-output`: CassiniBrowserControlTests/ControlServiceTests.swift:255: error: -[CassiniBrowserControlTests.ControlServiceTests testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart] : XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `audio-stop-all-output`: CassiniBrowserControlTests/ControlServiceTests.swift:285: error: -[CassiniBrowserControlTests.ControlServiceTests testRegisteredAudioThenDisconnectedStopAllBeforeAnyCaptureStatusCannotRestart] : XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `held-start-output`: CassiniBrowserControlTests/HeldStartTests.swift:271: error: -[CassiniBrowserControlTests.HeldStartTests testTheServiceCompletesALostStartOnceWhenTheRestartedLinkReportsTheCapture] : XCTAssertEqual failed: ("Optional("command")") is not equal to ("Optional("ping")") - A command preceded the output barrier
- `legacy-initial-output`: CassiniBrowserControlTests/D52HeartbeatTests.swift:145: error: -[CassiniBrowserControlTests.D52HeartbeatTests testALegacyHelloIsNeverPingedOrTimedOut] : XCTAssertNotNil failed - A legacy hello must not time out
- `legacy-frame-output`: CassiniBrowserControlTests/D52HeartbeatTests.swift:145: error: -[CassiniBrowserControlTests.D52HeartbeatTests testALegacyHelloIsNeverPingedOrTimedOut] : XCTAssertNotNil failed - A legacy hello must not time out
- `legacy-status-renegotiation`: CassiniBrowserControlTests/D52HeartbeatTests.swift:162: error: -[CassiniBrowserControlTests.D52HeartbeatTests testALegacyHelloIsNeverPingedOrTimedOut] : XCTAssertEqual failed: ("Optional("ping")") is not equal to ("Optional("command")") - A legacy peer must receive no heartbeat before the requested command
- `lost-peer-eof`: CassiniBrowserControlTests/D52HeartbeatTests.swift:112: error: -[CassiniBrowserControlTests.D52HeartbeatTests testPingsOverTheRealPipeAndSilenceLosesControl] : XCTAssertNil failed: threw error "timeout" - The lost connection must close; a receive timeout fails

Each committed patch is applied with `git apply --unidiff-zero`, then reversed
in finally. All mutated production files match their original hashes after
restoration. Separate 180-second build and 45-second test hang guards are
failures only. No success sleep, fixture-time condition or synthetic output
appears in these patches. Public receipt hashes match the restored scratch.
