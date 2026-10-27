#!/usr/bin/env python3
"""Bounded native diagnostic with persistent logs/results for self-hosted CI."""
import argparse, json, os, pathlib, signal, subprocess, time, uuid
parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=['sink-only', 'full'], default='full')
parser.add_argument('--artifacts', type=pathlib.Path, default=pathlib.Path('native-artifacts'))
parser.add_argument('--derived-data', type=pathlib.Path, default=pathlib.Path('build-native-ci'))
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
os.chdir(root)
artifacts = args.artifacts.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
derived = args.derived_data.resolve()
result = dict(mode=args.mode, status='running', phases=[], microphoneTested=False, generatedAudioOnly=True)

class AudioEnvironmentUnavailable(RuntimeError):
    pass

def save(): (artifacts / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
def run(command, name, timeout):
    with (artifacts / (name + '.log')).open('w') as output:
        process = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    if process.returncode: raise RuntimeError(f'{name} failed (exit {process.returncode}); see {name}.log')
    result['phases'].append(dict(name=name, status='passed')); save()

try:
    save()
    run(['xcodegen', 'generate'], 'generate', 60)
    run(['xcodebuild', '-project', 'Cassini.xcodeproj', '-scheme', 'Cassini', '-configuration', 'Debug',
         '-derivedDataPath', str(derived), 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_ALLOWED=YES', '-quiet', 'build'], 'build', 900)
    app = derived / 'Build/Products/Debug/Cassini.app'
    for mode in (['sink-only'] if args.mode == 'sink-only' else ['sink-only', 'tap']):
        output = artifacts / (mode + '.stdout.log'); error = artifacts / (mode + '.stderr.log')
        nonce = str(uuid.uuid4())
        flag = '--recording-sink-self-test' if mode == 'sink-only' else '--recording-self-test'
        # Only the hardware tap needs LaunchServices attribution. Sink checks are headless.
        if mode == 'sink-only':
            command = [str(app / 'Contents/MacOS/Cassini'), flag, '--recording-ci-run=' + nonce]
        else:
            command = ['open', '-n', '-W', '--stdout', str(output), '--stderr', str(error), '-a', str(app), '--args', flag, '--recording-ci-run=' + nonce]
        with output.open('w') as out, error.open('w') as err:
            process = subprocess.Popen(command, stdout=out if mode == 'sink-only' else subprocess.DEVNULL, stderr=err)
            try:
                process.wait(timeout=65)
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=10)
                    # Launch may stall before the app writes its PID. Match the unique nonce
                    # plus exact executable path instead; never terminate other Cassini apps.
                    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
                    for row in rows:
                        pid, _, identity = row.strip().partition(' ')
                        if nonce in identity and str(app / 'Contents/MacOS/Cassini') in identity:
                            try: os.kill(int(pid), signal.SIGTERM)
                            except ProcessLookupError: pass
        text = output.read_text() if output.exists() else ''
        print(text, end='')
        if 'RECORDING_SELF_TEST_PASSED' not in text:
            if mode == 'tap' and 'Timed out waiting for audio consent or a usable output device.' in text:
                raise AudioEnvironmentUnavailable('Native tap validation is blocked by audio consent or output-device readiness; no hardware pass is claimed.')
            raise RuntimeError(f'{mode} diagnostic did not pass; consent, output device, or capture behavior needs attention. See {output.name}')
        result['phases'].append(dict(name=mode, status='passed')); save()
    result['status'] = 'passed'
except AudioEnvironmentUnavailable as error:
    result['status'] = 'blocked'; result['blocker'] = 'audio-consent-or-output-device'; result['error'] = str(error); print(str(error))
except Exception as error:
    result['status'] = 'failed'; result['error'] = str(error); print(str(error))
finally:
    result['completedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()); save()
raise SystemExit(0 if result['status'] == 'passed' else 1)
