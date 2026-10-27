# Bundled, offline writing down (UX13)

Cassini runs one isolated worker at a time, in Library arrival order. An own,
finished recording without a transcript is queued automatically, including one
found after restarting the app. Received meetings require Write it down; failed
jobs require Try again. Explicitly writing down an opened external Opus makes a
private Received folder first, preserving the original.

The worker never changes session.json or audio. It updates app-owned meeting.json
through revision-preserving directory-locked transactions and publishes a private,
atomic transcript.json after every speech segment. The Library watcher updates the
open Meeting page. ETA uses remaining detected speech and the measured recognizer
realtime factor, initially 0.15. Missing alignment contributes a diagnostic and a
zero transcription offset, while playback retains the unknown alignment.

The D11 pipeline uses stereo channel averaging, the shared centred 97-tap FIR
`cassini-fir-48k-16k-v1`, and the cassini-live SpeechGate decisions with independent
Silero recurrent state per track. Input rates are exactly 16/48 kHz. Native WAV
reads physical complete PCM frames even when its checkpoint header is stale;
Opus uses offline AVAudioFile decoding. Decoder/resampler/gate memory is bounded.
Private 0700/0600 resampled scratch is removed on completion/failure; subsequent
workers clean only scratch belonging to dead processes of this user.

Whistle receives each segment as float32, automatic language, word timestamps on.
Words receive the track offset plus segment start and nearest-even rounded word
times. The merge is stable by time, session track ordinal, then word ordinal.
Microphone/local gives Me; system gives The others; browser remote tracks stay
unnamed, each track with its own identity. Received plain Opus always gives one
unnamed `track-original`, displayed as Speaker 1. No speaker recognition is claimed.

Build-time pins:

- Whistle/Needle pins remain in Whistle/pins.json (Apache-2.0).
- Silero model: snakers4/silero-vad 7e30209a3e901f9842f81b225f3e93d8199902b1,
  SHA256 1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3 (MIT).
- ONNX Runtime CPU universal2 1.23.2 official release archive,
  SHA256 49ae8e3a66ccb18d98ad3fe7f5906b6d7887df8a5edd40f49eb2b14e20885809 (MIT).
  The original runtime dylib SHA256 is 6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa.
- The C API headers are verbatim from that archive, with its licence alongside.
- Model and third-party notices live under Resources/Whistle; executable libraries
  live under Frameworks and are signed before the containing app. The sealed
  resource manifest checks actual signed code bytes; standalone tests require
  original source pins. The live privacy environment is checked before dlopen,
  and ONNX telemetry is disabled explicitly. No runtime download exists.

Offline tests cover exact FIR output tolerance/batch invariance, exact gate segment
boundaries, source identities, offsets including unknown alignment, revisions,
private files and unchanged capture data. Hosted ARM/Intel run both shared golden
inputs with the production model/recognizer. D11.3 permits at most 80 ms word-time
movement only after identical segment input hashes; text/count/boundaries remain
exact. D11.4 publishes a single approved Mac “ask”/“as” exception: only word 37
in segment 5 of whistle-golden, with its exact input SHA256, original golden
SHA256, and pinned Needle/model identity. The exception manifest is copied
verbatim with a compiled SHA256 check. Negative tests reject other words,
ordinals, inputs, boundaries and goldens. Recognizer output is never rewritten.

No test here starts a user's microphone, system tap, browser or playback device.
Native permission consent remains outside the fixture-based recording tests.
