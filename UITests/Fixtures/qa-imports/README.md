Generated one-second 440 Hz mono tones at 16 kHz, with no recorded speech or personal data.

Create each tone with the existing ffmpeg tool (no runtime dependency):

```sh
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a pcm_s16le tone.wav
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a aac tone.m4a
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a libmp3lame tone.mp3
ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=16000:duration=1 -c:a flac tone.flac
```

`LibraryBoards.testQAImportFormatsThroughOpenPanel` opens each file through the native picker in a fresh private fixture Library. The existing `meeting.opus` fixture covers portable Cassini import.
