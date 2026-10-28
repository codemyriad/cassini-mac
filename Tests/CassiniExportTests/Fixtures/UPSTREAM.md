The stereo-tone.opus fixture contains one second of generated mathematical tones, not a recording.

Generated with FFmpeg/libopus:

```sh
ffmpeg -f lavfi -i "aevalsrc=0.2*sin(2*PI*440*t)|0.2*sin(2*PI*880*t):s=48000:d=1" -c:a libopus -b:a 96k -ac 2 stereo-tone.opus
```

SHA256: `9164e850f33e1e8b00810ad925424046d44215fbd3870fea267927e30cae0459`.
The fixture checks packet preservation and real two-channel decoding on re-export.
