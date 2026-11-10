#!/usr/bin/env python3
"""Bounded, seeded audible-order cases; expectations come from the shared viewer generator.
Usage: generate-d84-audible-vectors.py WORK_DIR JITI SHARED_GENERATE_TS OUTPUT_JSON
Set VIEWER to an isolated gocassini 1111155 snapshot (never its working checkout).
"""
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys

work, jiti, generator, output = sys.argv[1:]
root = Path(work)
root.mkdir(parents=True, exist_ok=True)
shutil.copyfile(generator, root / 'generate.ts')
rng = random.Random(0xD84F2)
cases = []
for index in range(128):
    first = 1000 if index < 2 else rng.randint(500, 5000)
    shift = 0 if index < 2 else rng.randint(-25, 25)
    def w(speaker, start, end, text):
        return dict(speaker=speaker, startMs=start, endMs=end, text=text)
    items = [w('s1', 0, 0, 'um'), w('s1', first, first + 150, 'first')]
    if index % 2 == 0:
        items += [w('c', first-50, first+20, 'touch'),
                  w('s1', first-200+shift, first-50, 'second'),
                  w('b', first-40, first-10, 'aside'),
                  w('s1', first+20, first+500, 'third')]
    else:
        items += [w('b', first-300, first, 'competing'),
                  w('s1', first-200+shift, first, 'second')]
    name = f'audible-{index:03}'
    (root / (name + '.words.json')).write_text(json.dumps(dict(format='cassini.words.v1', items=items)))
    cases.append(dict(name=name, items=items))
subprocess.run([jiti, str(root / 'generate.ts')], check=True)
for case in cases:
    expected = json.loads((root / (case['name'] + '.expected.json')).read_text())
    case['rows'] = expected['rows']
Path(output).write_text(json.dumps(dict(source='gocassini 1111155cb0017b47c072a8662c54f28ad7c44223', seed=0xD84F2, cases=cases), indent=2) + '\n')
