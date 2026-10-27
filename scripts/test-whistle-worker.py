#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline worker/constructor-privacy test. Build-time assets must exist already."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SAFE = dict(NEEDLE_TELEMETRY='0', DO_NOT_TRACK='1', ORT_DISABLE_TELEMETRY='1')
def worker_env(**extra):
    return dict(SAFE,PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',LC_ALL='C',**extra)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', required=True, type=Path)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    pins = json.loads((ROOT / 'Whistle/pins.json').read_text())
    fixture = ROOT / 'Tests/CassiniWhistleTests/Fixtures'
    for name, expected in pins['fixtures'].items():
        assert hashlib.sha256((fixture / name).read_bytes()).hexdigest() == expected, name
    # A constructor makes load ordering observable: the unsafe invocation must
    # not load even one instruction of a dynamic library.
    with tempfile.TemporaryDirectory(prefix='cassini-whistle-privacy-') as temp:
        temp = Path(temp); source = temp / 'constructor.c'; library = temp / 'constructor.dylib'; marker = temp / 'loaded'
        source.write_text('''#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void loaded(void) {
 const char *p=getenv("CASSINI_TELEMETRY_SENTINEL");
 if(p){FILE *f=fopen(p,"w");if(f){fputs("loaded",f);fclose(f);}}
}
''')
        subprocess.run(['xcrun', 'clang', '-dynamiclib', str(source), '-o', str(library)], check=True)
        command = [str(args.worker.resolve()), '--library', str(library), '--model', str(args.bundle / 'whistle.cact')]
        for missing in SAFE:
            environment = worker_env(CASSINI_TELEMETRY_SENTINEL=str(marker)); environment.pop(missing)
            result = subprocess.run(command, input='', capture_output=True, text=True, env=environment, timeout=10)
            assert result.returncode == 78 and 'Required privacy environment missing' in result.stdout, result
            assert not marker.exists(), 'Unsafe worker loaded a library constructor'
        environment = worker_env(CASSINI_TELEMETRY_SENTINEL=str(marker))
        result = subprocess.run(command, input='', capture_output=True, text=True, env=environment, timeout=10)
        assert not marker.exists(), 'Unverified library was loaded'
        assert result.returncode == 78 and 'requires --assets' in result.stdout, result
        # Positive control outside the worker proves this constructor fixture is
        # observable; the worker has no bypass for loading an unpinned fixture.
        subprocess.run([sys.executable,'-c','import ctypes,sys; ctypes.CDLL(sys.argv[1])',str(library)],env=environment,check=True)
        assert marker.read_text() == 'loaded', 'Constructor sentinel did not exercise dlopen'
    # Supplied directories cannot bless arbitrary libraries or changed models.
    with tempfile.TemporaryDirectory(prefix='cassini-whistle-trust-') as temporary:
        temporary = Path(temporary)
        shutil.copyfile(args.bundle/'libneedle3.dylib',temporary/'libneedle3.dylib')
        shutil.copyfile(args.bundle/'whistle.cact',temporary/'whistle.cact')
        changed=temporary/'whistle.cact'
        with changed.open('r+b') as stream: stream.write(b'bad!')
        untrusted=[str(args.worker.resolve()),'--assets',str(temporary)]
        result=subprocess.run(untrusted,input='',capture_output=True,text=True,env=worker_env(),timeout=10)
        assert result.returncode==78 and 'checksum mismatch' in result.stdout,result
        shutil.copyfile(args.bundle/'whistle.cact',changed)
        (temporary/'libneedle3.dylib').write_bytes(b'not a pinned engine')
        result=subprocess.run(untrusted,input='',capture_output=True,text=True,env=worker_env(),timeout=10)
        assert result.returncode==78 and 'checksum mismatch' in result.stdout,result
    # The same child loads once and serves two requests, not one model per clip.
    command = [str(args.worker.resolve()), '--assets', str(args.bundle.resolve())]
    requests = [dict(id=str(i), wav=str(fixture / 'jfk.wav')) for i in range(2)]
    result = subprocess.run(command, input=''.join(json.dumps(r) + '\n' for r in requests), capture_output=True, text=True, env=worker_env(), timeout=60)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(responses) == 2 and [r['id'] for r in responses] == ['0', '1'], responses
    assert all('error' not in r for r in responses), responses
    text = responses[0]['transcript']['text']
    assert responses[1]['transcript'] == responses[0]['transcript'], 'Repeated worker request changed transcript'
    # Invalid files are rejected without following links, reading FIFO input or
    # allocating an oversized WAV; a subsequent good request still succeeds.
    with tempfile.TemporaryDirectory(prefix='cassini-whistle-input-') as temporary:
        temporary = Path(temporary)
        fifo = temporary/'fifo'; os.mkfifo(fifo)
        link = temporary/'link'; link.symlink_to(fixture/'jfk.wav')
        huge = temporary/'huge.wav'
        with huge.open('wb') as stream: stream.truncate(4_000_000)
        paths = [fifo, link, huge, fixture/'jfk.wav']
        bad = subprocess.run(command, input=''.join(json.dumps(dict(id=str(i),wav=str(p)))+'\n' for i,p in enumerate(paths)),
            capture_output=True,text=True,env=worker_env(),timeout=10)
        replies = [json.loads(line) for line in bad.stdout.splitlines()]
        assert bad.returncode==0 and len(replies)==4,(bad.returncode,bad.stdout,bad.stderr)
        assert all('error' in r for r in replies[:3]) and replies[-1]['transcript']['text']==text,replies
    too_long = subprocess.run(command,input='x'*1_000_000+'\n',capture_output=True,text=True,env=worker_env(),timeout=10)
    assert too_long.returncode==78 and 'tooLarge' in too_long.stdout,(too_long.returncode,too_long.stdout)
    read_fd, write_fd = os.pipe(); os.close(read_fd)
    try:
        closed = subprocess.run(command,input=json.dumps(requests[0])+'\n',stdout=write_fd,stderr=subprocess.PIPE,text=True,env=worker_env(),timeout=10)
        assert closed.returncode==78,closed.returncode
    finally: os.close(write_fd)
    reference = (fixture / 'jfk.txt').read_text().strip()
    words = lambda s: re.findall(r'\w+', s.casefold())
    assert words(text) == words(reference), (text, reference)
    report = dict(architecture=platform.machine(), engineVersion=pins['engineVersion'], text=text, reference=reference,
                  exactReferenceMatch=text == reference, wordReferenceMatch=True, twoRequestsIdentical=True,
                  constructorPrivacyGuard=True, boundedInputGuards=True, closedStdoutHandled=True, pinnedAssets=True, telemetry=SAFE)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
