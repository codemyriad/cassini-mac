#!/usr/bin/env python3
"""Diagnostic-only D: original verified SDK, bounded producer/late-event evidence."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def verify():
    # The engine, owner and renderer must match the failed run's SDK source.
    names = ['Sources/CassiniSpectrogram', 'Sources/CassiniRecording',
             'Sources/CassiniBrowserControl', 'Sources/CassiniLibrary', 'Sources/CassiniKit',
             'Cassini/Recording/RecordingSpectrogram.swift', 'Spikes/Spectrogram/Budget.swift',
             'Tests/CassiniRecordingTests/SpectrogramFixtureClock.swift']
    for name in names:
        source = ROOT / name
        paths = sorted(p for p in source.rglob('*') if p.is_file()) if source.is_dir() else [source]
        for path in paths:
            assert path.read_bytes() == (ROOT / 'sdk-source' / path.relative_to(ROOT)).read_bytes(), path
    print('Original SDK source matches every linked engine/owner module and native renderer; probe logging only.')


def run():
    assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    output = ROOT / 'build/d36-evidence'
    output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('probe_driver', ROOT / 'scripts/test-spectrogram-app.py')
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    setting = ['com.apple.universalaccess', 'reduceMotion']
    old = subprocess.run(['defaults', 'read', *setting], capture_output=True, text=True)
    try:
        subprocess.run(['defaults', 'write', *setting, '-bool', 'false'], check=True)
        command = driver.probe_command(ROOT / 'build/d36-evidence.app', 'D', output)
        command += ['-SpectrogramProducerEvidence', '1']
        with (output / 'D.stdout.txt').open('w') as stdout, (output / 'D.stderr.txt').open('w') as stderr:
            result = subprocess.run(command, env=dict(os.environ, CASSINI_SPECTRO='1'), stdout=stdout, stderr=stderr, timeout=90)
        proof = json.loads((output / 'D.stdout.txt').read_text())
        assert proof['diagnosticEvidenceOnly'] and proof['audioDevicesOpened'] is False
        assert not proof['omittedLateEvents'] and not proof['producerTiming']['omitted']
        (output / 'D.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps({key: proof[key] for key in ['lateColumns','steadyStateColumns','lateColumnFraction','gates','diagnosticEvidenceOnly']}))
        return result.returncode or int(not all(proof['gates'].values()))
    finally:
        command = ['defaults', 'write', *setting, '-bool', 'true' if old.stdout.strip() == '1' else 'false'] if old.returncode == 0 else ['defaults', 'delete', *setting]
        subprocess.run(command, check=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['verify']:verify()
    elif sys.argv[1:] == ['run']:sys.exit(run())
    else:raise SystemExit('Expected verify or run')
