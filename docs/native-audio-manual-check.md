# M4: consent and native tap waiting checks

Status on 2026-10-27: hardware validation pending genuine system-audio consent on DrMeyers.
The sink-only runner has passed; it does not test the process tap. No microphone input device
is present. Run this check after Cassini's system-audio permission has actually been granted.
Do not reset or write TCC, and do not infer consent from browser/tab-capture success.

## Full generated-tone gate

Run `python3 scripts/run-native-ci.py --mode full` on a Mac where Cassini's system-audio
permission has genuinely been granted (hosted CI runs only the sink-only phase). It tests only
Cassini's generated 440/880 Hz stereo tone, not other applications or the microphone. Record
the commit, the Mac and result.json from `native-artifacts/`. Require a
passed `tap` phase and `RECORDING_SELF_TEST_PASSED`, plus spectral separation in both channels.
Consent or output-device timeout remains `status: blocked` with a nonzero job exit.

The diagnostic's global 45-second watchdog also runs if a synchronous Core Audio start is
waiting. The Python launcher has a separate 65-second bound and matches only its own nonce
when cleaning up a diagnostic. These are diagnostic bounds, not a production UI timeout.

## Tap-only idle / zero-buffer manual check

Use a disposable test meeting/browser process with no live participants. Disable the microphone
in Cassini and choose only that process. Keep it idle initially, then play a known generated
tone; also test stopping playback after capture has begun. Record the timestamps below.

| Case | Observation to record | Passing behavior / interpretation |
| --- | --- | --- |
| Start while process is idle | Does AudioDeviceStart return? UI Starting/Recording state; any frames | Zero callbacks is waiting for source audio, not evidence of corrupt PCM |
| More than 5 s after a returned start, still zero frames | Waiting-for-audio notice, meters, Stop response | Notice should appear; saving no samples produces explicit interrupted/empty result |
| Start audio after the idle interval | First buffer/track start offset; rendered tone in saved WAV | One source starts on the session timeline without fabricated pre-audio samples |
| Pause after samples have arrived | Callback/frame count versus RMS level | Zero-valued PCM is valid silence; distinguish it from receiving no buffers |
| Stop / quit after audio | Response time, finalized WAV header/session state | Already-written samples remain playable; no late callback corrupts the session |

Important API limit: AudioHardware.h for kAudioAggregateDeviceTapAutoStartKey explicitly says
AudioDeviceStart waits until a tapped process receives its first audio. Cassini currently sets
that key on its private aggregate. The production controller's five-second waiting notice is
scheduled only after tap.start returns; it cannot diagnose a synchronous start that is still
waiting. Record that case as a production start/wait issue if it occurs. Do not claim the UI
watchdog covers it; moving start/cancellation off the UI actor would require a tested change.

Evidence source: Xcode 27 macOS SDK CoreAudio.framework/Headers/AudioHardware.h:1630,
AudioProcessTap.swift aggregate/start, and RecordingController.swift status timer. This is a
source-backed caveat, not a completed empirical hardware check.

Record macOS/Xcode version, app commit/path, output device, selected process, permission
outcome, idle/start/first-buffer/stop times, frame count, spectral result and run URL in
MAC-STATUS.md. Avoid saving other applications' audio. Missing microphone hardware remains a
separate manual gate even after the tap-only test passes.
