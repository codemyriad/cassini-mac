#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise production fixed-path setup with two exact host grants in a signed fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BROWSERS = ['Google/Chrome', 'Chromium', 'Microsoft Edge', 'BraveSoftware/Brave-Browser']
HOSTS = {'io.codemyriad.cassini': 'cassini-browser-host', 'io.codemyriad.cassini.control': 'cassini-control-host'}
ORIGIN = 'chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, help='Actual restored Debug app; required on hosted CI')
p.add_argument('--skip-build', action='store_true')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
hosted = os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1'
assert a.app or not hosted, 'Hosted proof must use the actual bundled service and hosts'
if not a.skip_build:
    for product in ['cassini-browser-connect-probe', 'cassini-browser-setup-service', *HOSTS.values()]:
        subprocess.run(['swift', 'build', '--jobs', '2', '--product', product], cwd=ROOT, check=True)


def profile(file):
    return plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', ':-', str(file)], check=True, capture_output=True).stdout)


def plist(file, data):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_bytes(plistlib.dumps(data))


parent_profile = plistlib.loads((ROOT/'Cassini/Cassini.entitlements').read_bytes())
production_profile = plistlib.loads((ROOT/'BrowserSetup/BrowserSetup.entitlements').read_bytes())
assert production_profile == {'com.apple.security.app-sandbox': True,
    'com.apple.security.temporary-exception.files.home-relative-path.read-write': [
        '/Library/Application Support/' + b + '/NativeMessagingHosts/' for b in BROWSERS]}
assert parent_profile['com.apple.security.app-sandbox'] and not parent_profile.get('com.apple.security.network.client')
if a.app:
    assert profile(a.app) == parent_profile
    assert profile(a.app/'Contents/XPCServices/CassiniBrowserSetup.xpc') == production_profile
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(a.app)], check=True)

(ROOT/'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='browser-connect-fixture-', dir=ROOT/'build') as temporary:
    base = Path(temporary).resolve()
    home = base/'home'
    relative = home.relative_to(Path(pwd.getpwuid(os.getuid()).pw_dir).resolve())
    for browser in BROWSERS:
        (home/'Library/Application Support'/browser/'NativeMessagingHosts').mkdir(parents=True, mode=0o700)
    app = base/'ConnectProbe.app'
    service = app/'Contents/XPCServices/CassiniBrowserSetup.xpc'
    binary = app/'Contents/MacOS/ProbeClient'
    binary.parent.mkdir(parents=True)
    shutil.copy2(ROOT/'.build/debug/cassini-browser-connect-probe', binary)
    plist(app/'Contents/Info.plist', dict(CFBundleIdentifier='io.codemyriad.cassini', CFBundleExecutable='ProbeClient',
        CFBundlePackageType='APPL', CFBundleVersion='1', LSBackgroundOnly=True))
    if a.app:
        shutil.copytree(a.app/'Contents/XPCServices/CassiniBrowserSetup.xpc', service)
    else:
        service_binary = service/'Contents/MacOS/CassiniBrowserSetup'
        service_binary.parent.mkdir(parents=True)
        shutil.copy2(ROOT/'.build/debug/cassini-browser-setup-service', service_binary)
        plist(service/'Contents/Info.plist', dict(CFBundleIdentifier='io.codemyriad.cassini.browser-setup',
            CFBundleExecutable='CassiniBrowserSetup', CFBundlePackageType='XPC!', CFBundleVersion='1', XPCService=dict(ServiceType='Application')))
    info = plistlib.loads((service/'Contents/Info.plist').read_bytes())
    info['CassiniSetupFixtureHome'] = str(home)
    plist(service/'Contents/Info.plist', info)
    for executable in HOSTS.values():
        source = a.app/'Contents/MacOS'/executable if a.app else ROOT/'.build/debug'/executable
        shutil.copy2(source, app/'Contents/MacOS'/executable)
    helper_profile = {'com.apple.security.app-sandbox': True,
        'com.apple.security.temporary-exception.files.home-relative-path.read-write': [
            '/' + (relative/'Library/Application Support'/b/'NativeMessagingHosts').as_posix() + '/' for b in BROWSERS]}
    parent_entitlements, helper_entitlements = base/'parent.plist', base/'helper.plist'
    plist(parent_entitlements, parent_profile); plist(helper_entitlements, helper_profile)
    for bundle, entitlements in [(service, helper_entitlements), (app, parent_entitlements)]:
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0', '--timestamp=none', '--entitlements', str(entitlements), str(bundle)], check=True)
    assert profile(app) == parent_profile and profile(service) == helper_profile
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    # The fixture owner can write these paths. Only the signed parent is denied.
    positive = home/'Library/Application Support/Google/Chrome/NativeMessagingHosts/client-must-not-write'
    positive.write_bytes(b'positive'); positive.unlink()
    # Seed only the generated fixture. The product service must remove its
    # own old registrations but preserve an unrelated file with our origin.
    unrelated = {}
    for browser in BROWSERS:
        directory = home/'Library/Application Support'/browser/'NativeMessagingHosts'
        for host, executable in HOSTS.items():
            old = host.replace('io.codemyriad.', 'com.codemyriad.', 1)
            (directory/(old+'.json')).write_text(json.dumps(dict(name=old,
                path='/Old Cassini.app/Contents/MacOS/'+executable,
                allowed_origins=['chrome-extension://old-origin/'])))
        other = directory/'unrelated.host.json'
        other.write_text(json.dumps(dict(name='com.codemyriad.cassini',path='/elsewhere/other-host',allowed_origins=[ORIGIN])))
        unrelated[other] = other.read_bytes()
    manifest_stats = {}
    for attempt in range(2):
        result = subprocess.run([str(binary), str(home)], capture_output=True, text=True, timeout=30)
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.with_suffix('.stderr.txt').write_text(result.stderr)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        report = json.loads(result.stdout)
        assert report == dict(manifestsWritten=8, parentWriteDenied=True, wrongHostBookmarkRejected=True), report
        for browser in BROWSERS:
            directory = home/'Library/Application Support'/browser/'NativeMessagingHosts'
            for host, executable in HOSTS.items():
                file = directory/(host+'.json')
                assert stat.S_IMODE(file.stat().st_mode) == 0o600
                observed = (file.stat().st_mtime_ns, file.stat().st_ino)
                if attempt:
                    assert observed == manifest_stats[file], ('Unchanged manifest was rewritten', file)
                else:
                    manifest_stats[file] = observed
                manifest = json.loads(file.read_text())
                assert manifest == dict(name=host, description='Cassini local meeting recorder',
                    path=str(app/'Contents/MacOS'/executable), type='stdio', allowed_origins=[ORIGIN])
            for host in HOSTS:
                old = host.replace('io.codemyriad.', 'com.codemyriad.', 1)
                assert not (directory/(old+'.json')).exists()
            assert (directory/'unrelated.host.json').read_bytes() == unrelated[directory/'unrelated.host.json']
            assert not positive.exists()
    report.update(fixtureOnly=True, actualBundledService=bool(a.app), twoIdempotentConnects=True,
        identicalMtimesPreserved=True, browserProfilesTouched=False, audioDevicesOpened=False, appWindowsOpened=False,
        exactProductParentProfile=True, ownLegacyHostsRemoved=True, unrelatedHostPreserved=True, scopedDirectories=4, helperNetworkEntitlements=False,
        nativeArchitecture=os.uname().machine)
    a.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS fixed-path production Connect RPC: eight manifests, repeat setup, parent denied, wrong host rejected')
