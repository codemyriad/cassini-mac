#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline worker/constructor-privacy test. Build-time assets must exist already."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import shutil
import signal
import tempfile
from worker_events import OWNER_TICK_FD, ENGINE_READY_FD, ProcessExit, json_line, watchdog_ticks, discard_ticks, engine_ready

ROOT = Path(__file__).resolve().parent.parent
SAFE = dict(NEEDLE_TELEMETRY='0', DO_NOT_TRACK='1', ORT_DISABLE_TELEMETRY='1')
def worker_env(**extra):
    return dict(SAFE,PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',LC_ALL='C',**extra)


def parked_fixture(worker):
    """Real DEBUG helper: cancellation and owner death, with no model or audio."""
    command = [str(worker.resolve()), '--fixture-wait-for-cancellation']
    for close_input in [False, True]:
        tick_read, tick_write = os.pipe()
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=worker_env(**{OWNER_TICK_FD:str(tick_write)}), pass_fds=(tick_write,))
        os.close(tick_write)
        try:
            if close_input: child.stdin.close()
            watchdog_ticks(tick_read)
            assert child.poll() is None, 'Parked fixture ended before cancellation'
            with ProcessExit(child.pid) as exited:
                child.terminate(); exited.wait()
            assert child.wait(timeout=10) == -signal.SIGTERM, 'Cancellation must stop the owned helper'
            assert child.stdout.read() == b'' and child.stderr.read() == b'', 'Parked fixture must not run inference'
        finally:
            if child.poll() is None: child.kill(); child.wait(timeout=10)
            child.stdin.close(); child.stdout.close(); child.stderr.close(); os.close(tick_read)
    # The same watchdog must stop a parked orphan even with stdin held open.
    read_fd, write_fd = os.pipe(); tick_read, tick_write = os.pipe()
    parent_script = '''import json,subprocess,sys,os
child=subprocess.Popen(sys.argv[2:],stdin=int(sys.argv[1]),stdout=sys.stdout,stderr=subprocess.DEVNULL,pass_fds=(int(os.environ['CASSINI_TEST_OWNER_TICK_FD']),))
print(json.dumps({'ownedChild':child.pid}),flush=True)
child.wait()
'''
    owner = subprocess.Popen([sys.executable,'-u','-c',parent_script,str(read_fd),*command],
        pass_fds=(read_fd,tick_write),stdout=subprocess.PIPE,bufsize=0,
        env=worker_env(**{OWNER_TICK_FD:str(tick_write)}))
    os.close(read_fd); os.close(tick_write)
    orphan = None
    try:
        orphan = json_line(owner.stdout)['ownedChild']
        watchdog_ticks(tick_read)
        assert owner.poll() is None, 'Parked worker owner ended before the test killed it'
        with ProcessExit(orphan) as exited:
            owner.kill(); owner.wait(timeout=10); exited.wait(); orphan = None
    finally:
        os.close(write_fd); os.close(tick_read)
        if owner.poll() is None: owner.kill(); owner.wait(timeout=10)
        if orphan:
            try: os.kill(orphan,signal.SIGKILL)
            except ProcessLookupError: pass
        owner.stdout.close()
    return dict(parkedFixtureCancellation=True,parkedFixtureIgnoresEOF=True,parkedFixtureOwnerDeath=True)



# The same outer hang guard as normal real inference. Completion requires a
# response or process exit; model startup is acknowledged before fatal probes.
WORKER_HANG_GUARD = 60

@contextmanager
def worker_session(command):
    # Separate startup from the first stdin/stdout operation without adding a
    # protocol message or priming the parser/SIGPIPE state with an earlier write.
    with tempfile.TemporaryFile() as diagnostics:
        ready_read, ready_write = os.pipe(); child = None
        try:
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=diagnostics, env=worker_env(**{ENGINE_READY_FD:str(ready_write)}),
                pass_fds=(ready_write,), bufsize=0)
            os.close(ready_write); ready_write = None
            engine_ready(ready_read, timeout=WORKER_HANG_GUARD)
            yield child
        except BaseException:
            if child is not None:
                if child.poll() is None: child.kill(); child.wait(timeout=10)
                if not child.stdout.closed:
                    output = child.stdout.read()
                    if output: print(output.decode(errors='replace'), file=sys.stderr)
            diagnostics.seek(0)
            output = diagnostics.read()
            if output: print(output.decode(errors='replace'), file=sys.stderr)
            raise
        finally:
            os.close(ready_read)
            if ready_write is not None: os.close(ready_write)
            if child is not None:
                if child.poll() is None: child.kill(); child.wait(timeout=10)
                child.stdin.close(); child.stdout.close()


def fails_before_ready(command, environment):
    ready_read, ready_write = os.pipe()
    try:
        result = subprocess.run(command, input='', capture_output=True, text=True,
            env=dict(environment,**{ENGINE_READY_FD:str(ready_write)}),
            pass_fds=(ready_write,), timeout=10)
        os.close(ready_write); ready_write = None
        assert os.read(ready_read,1) == b'', 'Rejected invocation announced an initialized engine'
        return result
    finally:
        os.close(ready_read)
        if ready_write is not None: os.close(ready_write)


def worker_request(child, request):
    child.stdin.write((json.dumps(request)+'\n').encode()); child.stdin.flush()
    response = json_line(child.stdout, timeout=WORKER_HANG_GUARD)
    assert response.get('id') == request['id'], response
    return response

def exercise_requests(command, fixture):
    requests = [dict(id=str(i), wav=str(fixture/'jfk.wav')) for i in range(2)]
    with worker_session(command) as child:
        responses = [worker_request(child, request) for request in requests]
        assert all('error' not in response for response in responses), responses
        text = responses[0]['transcript']['text']
        assert responses[1]['transcript'] == responses[0]['transcript'], 'Repeated worker request changed transcript'
        # Reuse that initialized child for invalid inputs and the good recovery
        # request. FIFO/link/oversize rejection and recovery assertions are intact.
        with tempfile.TemporaryDirectory(prefix='cassini-whistle-input-') as temporary:
            temporary = Path(temporary)
            fifo = temporary/'fifo'; os.mkfifo(fifo)
            link = temporary/'link'; link.symlink_to(fixture/'jfk.wav')
            huge = temporary/'huge.wav'
            with huge.open('wb') as stream: stream.truncate(4_000_000)
            paths = [fifo, link, huge, fixture/'jfk.wav']
            replies = [worker_request(child, dict(id=f'input-{i}', wav=str(path))) for i,path in enumerate(paths)]
            assert all('error' in reply for reply in replies[:3]) and replies[-1].get('transcript',{}).get('text') == text, replies
        with ProcessExit(child.pid) as exited:
            child.stdin.close(); exited.wait(timeout=WORKER_HANG_GUARD)
        assert child.wait(timeout=10) == 0 and child.stdout.read() == b'', 'Worker must finish cleanly at EOF without extra responses'
    with worker_session(command) as child:
        output, _ = child.communicate(input=b'x'*1_000_000+b'\n', timeout=WORKER_HANG_GUARD)
        assert child.returncode == 78 and b'tooLarge' in output, (child.returncode,output)
    with worker_session(command) as child:
        with ProcessExit(child.pid) as exited:
            child.stdout.close()
            child.stdin.write((json.dumps(requests[0])+'\n').encode()); child.stdin.close()
            exited.wait(timeout=WORKER_HANG_GUARD)
        assert child.wait(timeout=10) == 78, child.returncode
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', required=True, type=Path)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    parked = parked_fixture(args.worker)
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
            result = fails_before_ready(command, environment)
            assert result.returncode == 78 and 'Required privacy environment missing' in result.stdout, result
            assert not marker.exists(), 'Unsafe worker loaded a library constructor'
        environment = worker_env(CASSINI_TELEMETRY_SENTINEL=str(marker))
        result = fails_before_ready(command, environment)
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
        result=fails_before_ready(untrusted,worker_env())
        assert result.returncode==78 and 'checksum mismatch' in result.stdout,result
        shutil.copyfile(args.bundle/'whistle.cact',changed)
        (temporary/'libneedle3.dylib').write_bytes(b'not a pinned engine')
        result=fails_before_ready(untrusted,worker_env())
        assert result.returncode==78 and 'checksum mismatch' in result.stdout,result
    # Hold stdin open in the grandparent: the orphan cannot pass this test by
    # simply seeing EOF. First complete real inference, then kill only its owner.
    read_fd, write_fd = os.pipe(); tick_read, tick_write = os.pipe()
    parent_script = """import json,subprocess,sys,os
child=subprocess.Popen(sys.argv[2:],stdin=int(sys.argv[1]),stdout=sys.stdout,stderr=subprocess.DEVNULL,pass_fds=(int(os.environ['CASSINI_TEST_OWNER_TICK_FD']),))
print(json.dumps({'ownedChild':child.pid}),flush=True)
child.wait()
"""
    owner = subprocess.Popen([sys.executable,'-u','-c',parent_script,str(read_fd),str(args.worker.resolve()),'--assets',str(args.bundle.resolve())],pass_fds=(read_fd,tick_write),stdout=subprocess.PIPE,bufsize=0,env=worker_env(**{OWNER_TICK_FD:str(tick_write)}))
    os.close(read_fd); os.close(tick_write)
    orphan = None
    def owner_line(): return json_line(owner.stdout)
    try:
        orphan=owner_line()['ownedChild']
        request=json.dumps(dict(id='owner-proof',wav=str(fixture/'jfk.wav')))+'\n'
        os.write(write_fd,request.encode())
        response=owner_line();assert response['id']=='owner-proof' and 'error' not in response,response
        discard_ticks(tick_read)
        watchdog_ticks(tick_read)
        assert owner.poll() is None,'Worker died while its owner was still alive across watchdog ticks'
        with ProcessExit(orphan) as exited:
            owner.kill();owner.wait(timeout=10)
            exited.wait();orphan=None
    finally:
        os.close(write_fd)
        if owner.poll() is None:owner.kill();owner.wait(timeout=10)
        if orphan:
            try:os.kill(orphan,signal.SIGKILL)
            except ProcessLookupError:pass
        os.close(tick_read)

    command = [str(args.worker.resolve()), '--assets', str(args.bundle.resolve())]
    text = exercise_requests(command, fixture)
    reference = (fixture / 'jfk.txt').read_text().strip()
    words = lambda s: re.findall(r'\w+', s.casefold())
    assert words(text) == words(reference), (text, reference)
    report = dict(architecture=platform.machine(), engineVersion=pins['engineVersion'], text=text, reference=reference,
                  exactReferenceMatch=text == reference, wordReferenceMatch=True, twoRequestsIdentical=True,
                  constructorPrivacyGuard=True, orphanStopsWithoutEOF=True, boundedInputGuards=True, closedStdoutHandled=True, pinnedAssets=True, telemetry=SAFE)
    report.update(parked)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Preserve the original failure. A second, debugger-owned public JFK
        # probe gives a native backtrace when hosted CrashReporter is disabled.
        try:
            worker = Path(sys.argv[sys.argv.index('--worker')+1]).resolve()
            bundle = Path(sys.argv[sys.argv.index('--bundle')+1]).resolve()
            report = Path(sys.argv[sys.argv.index('--report')+1]).resolve()
            directory = report.parent/'whistle-crashes'; directory.mkdir(parents=True,exist_ok=True)
            requests = directory/'debug-requests.jsonl'
            requests.write_text(''.join(json.dumps(dict(id=str(i),wav=str(ROOT/'Tests/CassiniWhistleTests/Fixtures/jfk.wav')))+'\n' for i in range(2)))
            command = ['xcrun','lldb','--batch','-o',
                       'process launch -i '+str(requests)+' -o '+str(directory/'debug-stdout.txt')+' -e '+str(directory/'debug-stderr.txt'),
                       '-k','thread backtrace all','--',str(worker),'--assets',str(bundle)]
            debug = subprocess.run(command,env=worker_env(),capture_output=True,text=True,timeout=90)
            (directory/'lldb.txt').write_text(debug.stdout+'\n'+debug.stderr)
        except Exception as diagnostic_error:
            print('Worker diagnostic could not complete:',repr(diagnostic_error),file=sys.stderr)
        raise
