#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""D38.3 scoring with the shared measure.py truth spans; never opens audio devices."""
import argparse
import json
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT/'Tests/CassiniTranscriptionTests/Fixtures/Echo/Recordings'


def spans(path):
    # Same 10 ms peak >300, 500 ms gap and 500 ms word-tail convention
    # as coordination ux-draft/bleed/measure.py. Use the clean source WAVs.
    with wave.open(str(path)) as stream:
        assert stream.getframerate() == 16000 and stream.getnchannels() == 1
        raw = stream.readframes(stream.getnframes())
    samples = struct.unpack('<'+'h'*(len(raw)//2), raw)
    loud = [max(map(abs, samples[index:index+160])) > 300 for index in range(0, len(samples), 160)]
    result, start, quiet = [], None, 0
    for index, on in enumerate(loud+[False]*60):
        if on:
            start = index if start is None else start
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= 50:
                result.append((start*10, (index-quiet+1)*10))
                start, quiet = None, 0
    return result


def check(directory):
    clean = FIXTURES/'Recording-b1eed000-0000-4000-8000-000000000001'
    truth = sorted([(a,b,'me') for a,b in spans(clean/'track-microphone.wav')]+
                   [(a,b,'others') for a,b in spans(clean/'track-system.wav')])
    def speaker(word):
        middle = (word['startMs']+word['endMs'])/2
        return next((who for a,b,who in truth if a <= middle <= b+500), None)
    results = {}
    for name in ['clean', 'bleed', 'room']:
        body = json.loads((directory/('echo-'+name+'.json')).read_text())
        words = body['items']
        visible = [word for word in words if word.get('echo') is not True]
        echoes = sum(word['speaker'] == 'me' and speaker(word) == 'others' for word in visible)
        own_dropped = sum(word['speaker'] == 'me' and speaker(word) == 'me' and word.get('echo') is True for word in words)
        turns = sum(index == 0 or visible[index-1]['speaker'] != word['speaker'] for index,word in enumerate(visible))
        assert echoes <= 2 and turns <= 10 and own_dropped == 0, (name, echoes, turns, own_dropped)
        if name == 'clean':
            assert words == visible, 'Clean output changed'
        projected = dict(body, items=visible)
        (directory/('echo-'+name+'-visible.json')).write_text(json.dumps(projected, indent=2)+'\n')
        results[name] = dict(rawWords=len(words), flagged=len(words)-len(visible), echoWordsLeft=echoes, displayedTurns=turns, ownWordsDropped=own_dropped)
    (directory/'echo-metrics.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', type=Path)
    check(parser.parse_args().reports)
