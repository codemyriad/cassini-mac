from pathlib import Path
import difflib
import os
import signal
import subprocess

root = Path('/tmp/cassini-aws-d88-transport')
baseline = Path('/tmp/cassini-aws-d88-before')
evidence = root / 'evidence/mac/d88/aws-transport'
test_file = Path('Tests/CassiniBrowserControlTests/PipeTransportTests.swift')
test_name = 'testSlowFragmentedPeerDoesNotBlockAnotherOrLoseItsPartialFrame'
focused = f'PipeTransportTests.{test_name}'
suite = 'PipeTransportTests|ControlHostTests|FrameIOTests|ModelSupersessionTests|TranscriptionMeetingTests.testSidecarWriteObserverReadsCommittedBytesForGeneratedSilence'

assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=baseline, text=True).strip()
paths = subprocess.check_output(['git', 'diff', 'main', '--name-only'], cwd=root, text=True).splitlines()
paths = [Path(p) for p in paths if p.startswith(('Sources/', 'Tests/')) or p in ('Package.swift', 'Package.resolved')]
assert test_file in paths
originals = {p: (baseline/p).read_bytes() if (baseline/p).is_file() else None for p in paths}
env = dict(os.environ, CASSINI_PIPELINE_ASSETS=str(Path.home()/'work/cassini-mac/build/Whistle'),
           NEEDLE_TELEMETRY='0', DO_NOT_TRACK='1', ORT_DISABLE_TELEMETRY='1')

def run(name, selection, expected_exit):
    output = evidence / (name + '.log')
    with output.open('w') as log:
        proc = subprocess.Popen(['swift','test','--package-path',str(baseline),
                                 '--scratch-path','/tmp/cassini-aws-d88-before-build',
                                 '--jobs','4','--filter',selection],
                                env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=180)
        except BaseException:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            raise
    print(name, code, flush=True)
    assert code == expected_exit, output
    return output.read_text()

try:
    for path in paths:
        target = baseline/path
        if (root/path).is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((root/path).read_bytes())
        elif target.exists():
            target.unlink()
    original = (baseline/test_file).read_text()
    assert f'{test_name}]\' passed' in run('review-bounds-after', focused, 0)
    before, method = original.split(f'    func {test_name}() throws {{', 1)
    echo = 'received:{ peer,data in try peer.send(data) }'
    assert echo in method
    suppressed = '''received:{ peer,data in
            let independent = Data("{\\"type\\":\\"future\\",\\"body\\":\\"independent\\"}".utf8)
            if data == (try FrameIO.normalized(independent)) {
                print("Mutation suppressed the second peer reply and left the connection open")
                return
            }
            try peer.send(data)
        }'''
    mutated = before + f'    func {test_name}() throws {{' + method.replace(echo, suppressed, 1)
    (evidence/'suppressed-second-reply.patch').write_text(''.join(difflib.unified_diff(
        original.splitlines(keepends=True), mutated.splitlines(keepends=True),
        fromfile=f'a/{test_file}', tofile=f'b/{test_file}')))
    (baseline/test_file).write_text(mutated)
    mutation = run('suppressed-second-reply', focused, 1)
    assert 'Mutation suppressed the second peer reply and left the connection open' in mutation
    assert f'{test_name} : caught error: "timeout"' in mutation or (
        f'{test_name}]' in mutation and 'caught error: "timeout"' in mutation)
    (baseline/test_file).write_text(original)
    restored = run('review-bounds-restored', suite, 0)
    assert f'{test_name}]\' passed' in restored
finally:
    for path, data in originals.items():
        target = baseline/path
        if data is None:
            target.unlink(missing_ok=True)
        else:
            target.write_bytes(data)
