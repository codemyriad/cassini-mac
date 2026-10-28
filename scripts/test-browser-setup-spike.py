#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private UX10 XPC/file-scope proof; never touches a real browser profile."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import socket
import socketserver
import stat
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
BROWSERS = ['Google/Chrome', 'Chromium', 'Microsoft Edge', 'BraveSoftware/Brave-Browser']
HOSTS = ['com.codemyriad.cassini', 'com.codemyriad.cassini.control']
ORIGIN = 'chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS') == '1' or (
    os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'), 'Explicit private-workflow opt-in required'
if not args.skip_build:
    for product in ['cassini-browser-setup-probe-client', 'cassini-browser-setup-probe-service']:
        subprocess.run(['swift', 'build', '--jobs', '2', '--product', product], cwd=ROOT, check=True)


def plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def profile(path):
    return plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True).stdout)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        pass


build = ROOT / 'build'
build.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='browser-setup-spike-', dir=build) as temporary:
    temporary = Path(temporary).resolve()
    home = temporary / 'fixture-home'
    # Home-relative entitlements resolve against the real account home. No HOME
    # override and no access to its real browser directories are needed.
    account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    relative_home = home.relative_to(account_home)
    for browser in BROWSERS:
        (home / 'Library/Application Support' / browser / 'NativeMessagingHosts').mkdir(parents=True, mode=0o700)
    identifier = 'com.codemyriad.cassini-browser-setup-spike'
    app = temporary / 'BrowserSetupProbe.app'
    service = app / 'Contents/XPCServices/BrowserSetupProbe.xpc'
    client_binary = app / 'Contents/MacOS/ProbeClient'
    service_binary = service / 'Contents/MacOS/ProbeService'
    for target, product in [(client_binary, 'cassini-browser-setup-probe-client'), (service_binary, 'cassini-browser-setup-probe-service')]:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / '.build/debug' / product, target)
        assert set(subprocess.check_output(['xcrun', 'lipo', '-archs', str(target)], text=True).split()) == {os.uname().machine}
    plist(app / 'Contents/Info.plist', dict(CFBundleIdentifier=identifier, CFBundleExecutable='ProbeClient',
          CFBundleName='Cassini browser setup probe', CFBundlePackageType='APPL', CFBundleVersion='1', LSBackgroundOnly=True))
    plist(service / 'Contents/Info.plist', dict(CFBundleIdentifier=identifier + '.setup', CFBundleExecutable='ProbeService',
          CFBundlePackageType='XPC!', CFBundleVersion='1', XPCService=dict(ServiceType='Application'),
          ProbeFixtureHome=str(home), ProbeHostExecutable=str(client_binary)))
    parent_profile = plistlib.loads((ROOT / 'Cassini/Cassini.entitlements').read_bytes())
    assert parent_profile['com.apple.security.app-sandbox'] and not parent_profile.get('com.apple.security.network.client')
    helper_profile = {'com.apple.security.app-sandbox': True,
        'com.apple.security.temporary-exception.files.home-relative-path.read-write': [
            '/' + (relative_home / 'Library/Application Support' / browser / 'NativeMessagingHosts').as_posix() + '/' for browser in BROWSERS]}
    parent_entitlements, helper_entitlements = temporary / 'parent.plist', temporary / 'helper.plist'
    plist(parent_entitlements, parent_profile); plist(helper_entitlements, helper_profile)
    for bundle, entitlements in [(service, helper_entitlements), (app, parent_entitlements)]:
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0', '--timestamp=none',
                        '--entitlements', str(entitlements), str(bundle)], check=True)
    assert profile(app) == parent_profile and profile(service) == helper_profile
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    # These paths are writable by the fixture owner; denial must come from the
    # signed process roles, not a missing directory or POSIX permission error.
    for leaf in ['NativeMessagingHosts/client-must-not-write', 'not-a-host-manifest']:
        positive = home / 'Library/Application Support/Google/Chrome' / leaf
        positive.write_text('positive control'); positive.unlink()
    with socketserver.TCPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            with socket.create_connection(server.server_address, timeout=2):
                pass
            result = subprocess.run([str(client_binary), str(home), str(server.server_address[1])], capture_output=True, text=True, timeout=30)
        finally:
            server.shutdown(); thread.join(timeout=5)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix('.stderr.txt').write_text(result.stderr)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    report = json.loads(result.stdout)
    assert 'error' not in report, report
    assert report['manifestsWritten'] == 8, report
    for key in ['parentWriteDenied', 'outsideLeafWriteDenied', 'helperNetworkDenied']:
        assert report[key] is True, (key, report)
    for browser in BROWSERS:
        directory = home / 'Library/Application Support' / browser / 'NativeMessagingHosts'
        for host in HOSTS:
            path = directory / (host + '.json')
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            assert json.loads(path.read_text()) == dict(name=host, description='Generated Cassini setup probe',
                type='stdio', path=str(client_binary), allowed_origins=[ORIGIN])
        assert not (directory / 'client-must-not-write').exists()
    assert not (home / 'Library/Application Support/Google/Chrome/not-a-host-manifest').exists()
    report.update(fixtureOnly=True, browserProfilesTouched=False, audioDevicesOpened=False, appWindowsOpened=False,
                  nativeArchitecture=os.uname().machine, exactProductParentProfile=True, scopedDirectories=4, positiveControls=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS UX10 private XPC scope: eight manifests, parent/sibling writes denied, helper networking denied')
