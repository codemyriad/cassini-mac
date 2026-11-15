Generated tones with no recorded speech or personal data. WAV/M4A/MP3/FLAC
contain one second of 440 Hz mono audio at 16 kHz. Their distinct file stems
identify the format in the picker, selected row and detail heading.

Regenerate with ffmpeg (no runtime dependency):

```sh
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a pcm_s16le tone-wav.wav
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a aac tone-m4a.m4a
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a libmp3lame tone-mp3.mp3
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a flac tone-flac.flac
ffmpeg -v error -f lavfi -i sine=frequency=880:sample_rate=16000:duration=1 -c:a pcm_s16le tone-batch.wav
```

`tone-opus.opus` is one second of 660 Hz audio encoded with ffmpeg/libopus at
48 kHz, then wrapped with cassini-format/tools/cassini-pack.py using title
`tone-opus`, created-at `2026-09-01T00:00:00Z` and an empty word transcript
(`{"speakers": [], "items": []}`). It covers portable Cassini import.

`LibraryBoards.testQAImportFormatsThroughOpenPanel` opens each format through
the native picker in a fresh private fixture Library. `tone-batch.wav` has a
different audio digest so the duplicate/truncated/valid batch has one success.
