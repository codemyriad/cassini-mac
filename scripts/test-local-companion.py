#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-only real guide installation; no app build, store access or profile injection."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted', 'Disposable hosted Mac only'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.app.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    keys = output.parent/'local-companion-keys'
    subprocess.run(['clang',ROOT/'Spikes/BrowserGuide/keys.c','-framework','ApplicationServices','-o',keys],check=True)
    home = Path.home()
    profile = home/'Library/Application Support/Google/Chrome for Testing'
    companion = home/'Library/Application Support/Cassini/BrowserCompanion'
    assert not profile.exists() and not profile.is_symlink(), 'Fresh browser account required'
    assert not companion.exists() and not companion.is_symlink(), 'Fresh local companion required'
    browser = Path(subprocess.check_output(['node', '--input-type=module', '-e',
        "import {chromium} from './BrowserExtension/tests/node_modules/playwright/index.mjs'; console.log(chromium.executablePath())"], cwd=ROOT, text=True).strip().split('/Contents/')[0])
    assert plistlib.loads((browser/'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'com.google.chrome.for.testing'
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', browser], check=True)
    with tempfile.TemporaryDirectory(prefix='local-companion-gate-', dir=ROOT/'build') as temporary:
        base = Path(temporary)
        app, next_app = base/'N/Cassini.app', base/'N-plus-1/Cassini.app'
        for target in [app, next_app]:
            target.parent.mkdir()
            subprocess.run(['ditto', source, target], check=True)
        manifest = next_app/'Contents/Resources/BrowserCompanion/manifest.json'
        original = json.loads(manifest.read_text())
        parts = list(map(int, original['version'].split('.')))
        assert parts[-1] < 65535
        parts[-1] += 1
        newer = '.'.join(map(str, parts))
        original['version'] = newer
        manifest.write_text(json.dumps(original, indent=2)+'\n')
        info_file = next_app/'Contents/Info.plist'
        info = plistlib.loads(info_file.read_bytes())
        info['CFBundleVersion'] = str(int(info['CFBundleVersion'])+1)
        info_file.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0', '--timestamp=none', '--entitlements', ROOT/'Cassini/Cassini.entitlements', next_app], check=True)
        for target in [source, app, next_app]:
            subprocess.run(['codesign', '--verify', '--deep', '--strict', target], check=True)
        config = base/'config.json'
        config.write_text(json.dumps(dict(app=str(app), nextApp=str(next_app), browser=str(browser), profile=str(profile),
            installed=str(companion/'extension'), newVersion=newer, output=str(output/'report.json'))))
        env = dict(os.environ, TEST_RUNNER_CASSINI_LOCAL_GUIDE_GATE='1', TEST_RUNNER_CASSINI_LOCAL_GUIDE_CONFIG=str(config),
            TEST_RUNNER_CASSINI_LOCAL_GUIDE_KEYS=str(keys))
        test_run = next((ROOT/'build/Build/Products').glob('*.xctestrun'))
        try:
            with (output/'xctest.log').open('wb') as log:
                result = subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', test_run, '-destination', 'platform=macOS',
                    '-parallel-testing-enabled', 'NO', '-only-testing:CassiniWindowScreenshots/LocalCompanionInstall',
                    '-resultBundlePath', output/'Install.xcresult'], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=360)
            if result.returncode:
                lines = (output/'xctest.log').read_text(errors='replace').splitlines()
                print('\n'.join(line for line in lines if any(marker in line for marker in
                    ['error:','Failed to','Browser focus:','Hosted keyboard post access:'])), flush=True)
                raise AssertionError('Real guide failed; inspect xctest.log and Install.xcresult')
            report = json.loads((output/'report.json').read_text())
            assert report['loadedID'] == 'pcafdaahfhjiolfpfnlhmljfgoabbaij' and report['realNativeHandshake']
            assert report['newerAppFolderReplaced'] and report['repeatLaunchDidNotRewrite']
            subprocess.run(['codesign', '--verify', '--deep', '--strict', source], check=True)
            print('PASS actual copy-address/Developer mode/Load unpacked/native handshake and newer-app folder update')
        finally:
            # Both paths were absent at entry, on a fresh hosted account. Preserve
            # all diagnostics outside these test-owned directories.
            for target in [profile, companion]:
                if target.exists() and not target.is_symlink(): shutil.rmtree(target)
            if (output/'Install.xcresult').exists():
                subprocess.run(['xcrun','xcresulttool','export','attachments','--path',output/'Install.xcresult',
                    '--output-path',output/'attachments'], check=False)


if __name__ == '__main__':
    main()
