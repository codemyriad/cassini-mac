#!/usr/bin/env python3
"""M3 integration check: disposable, non-login macOS account and standard Chrome paths.
Run with sudo. Removes only the account/home created by this invocation.
"""
import argparse, json, os, pathlib, shutil, struct, subprocess, tempfile, uuid
parser = argparse.ArgumentParser()
parser.add_argument('archive', type=pathlib.Path)
parser.add_argument('--report', type=pathlib.Path, required=True)
args = parser.parse_args()
assert os.geteuid() == 0, 'Run with sudo for the disposable local-account check'
archive, report = args.archive.resolve(), args.report.resolve()
assert archive.is_file()
name = 'cassini_m3_' + uuid.uuid4().hex[:8]
workspace = pathlib.Path(tempfile.mkdtemp(prefix='cassini-clean-install-', dir='/private/tmp'))
workspace.chmod(0o755)
home = workspace / 'home'; home.mkdir(mode=0o700)
account = '/Users/' + name
created = False
result = dict(status='running', account=name, normalChromeProfile=True, swiftCompilerInvoked=False, checks=[])
def root_run(*command): return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)
def as_user(*command, data=None):
    return subprocess.run(['/usr/bin/sudo', '-n', '-H', '-u', name, '/usr/bin/env', '-i',
        'HOME=' + str(home), 'USER=' + name, 'LOGNAME=' + name, 'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
        'DEVELOPER_DIR=/no-developer-tools-for-cassini-install-test', *map(str, command)],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
def ok(process):
    assert process.returncode == 0, (process.returncode, process.stdout.decode(errors='replace'), process.stderr.decode(errors='replace'))
    return process.stdout
try:
    listing = root_run('/usr/bin/dscl', '.', '-list', '/Users', 'UniqueID')
    ids = [int(line.rsplit(None, 1)[1]) for line in listing.splitlines()]
    uid = max([value for value in ids if 500 <= value < 60000] + [500]) + 1
    assert subprocess.run(['/usr/bin/dscl', '.', '-read', account], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    root_run('/usr/bin/dscl', '.', '-create', account); created = True
    for key, value in [('UniqueID', str(uid)), ('PrimaryGroupID', '20'), ('UserShell', '/usr/bin/false'),
                       ('NFSHomeDirectory', str(home)), ('RealName', 'Cassini temporary release installation check'), ('IsHidden', '1')]:
        root_run('/usr/bin/dscl', '.', '-create', account, key, value)
    os.chown(home, uid, 20)
    root_run('/usr/bin/ditto', '-x', '-k', str(archive), str(workspace))
    release = workspace / 'Cassini'
    host = release / 'Cassini.app/Contents/MacOS/cassini-browser-host'
    installer = release / 'Install Browser Host.command'
    chrome = home / 'Library/Application Support/Google/Chrome'
    ok(as_user('/bin/mkdir', '-p', chrome))
    extension_id = 'a' * 32
    ok(as_user('/bin/bash', installer, extension_id))
    path = chrome / 'NativeMessagingHosts/com.codemyriad.cassini.json'
    manifest = json.loads(path.read_text())
    assert pathlib.Path(manifest['path']).resolve() == host.resolve(), manifest
    assert manifest['allowed_origins'] == [f'chrome-extension://{extension_id}/']
    assert path.stat().st_uid == uid and path.stat().st_mode & 0o777 == 0o600
    assert not (home / 'Library/Application Support/Microsoft Edge').exists()
    result['checks'].append('installer uses bundled helper and standard user Chrome NativeMessagingHosts path')
    packets = [dict(type='start', title='M3 clean-account test'), dict(type='track', id='x', kind='tab', sampleRate=48000, channels=1),
               dict(type='audio', id='x', sequence=0, offsetMs=0, pcm='AQACAA=='), dict(type='stop')]
    wire = b''
    for packet in packets:
        data = json.dumps(packet).encode(); wire += struct.pack('=I', len(data)) + data
    output = ok(as_user(host, f'chrome-extension://{extension_id}/', data=wire))
    responses = []
    while output:
        length, = struct.unpack('=I', output[:4]); responses.append(json.loads(output[4:4+length])); output = output[4+length:]
    assert [response['type'] for response in responses] == ['started', 'ack', 'ack', 'stopped'], responses
    session = pathlib.Path(responses[0]['path']).resolve()
    home = home.resolve()
    assert session.is_relative_to(home) if hasattr(session, 'is_relative_to') else str(session).startswith(str(home) + '/')
    metadata = json.loads((session / 'session.json').read_text())
    assert metadata['state'] == 'completed' and metadata['tracks'][0]['frames'] == 2
    result['checks'].append('bundled Release host records and finalizes in the actual clean account')
    ok(as_user('/bin/bash', installer, '--uninstall'))
    assert not path.exists() and (session / 'session.json').exists()
    result['checks'].append('uninstall removes registration and retains recordings')
    result['status'] = 'passed'
    result['scope'] = 'Actual clean macOS account, command installer and native stdio. Interactive Chrome loading/Gatekeeper approval remain manual.'
except Exception as error:
    result['status'] = 'failed'; result['error'] = str(error)
finally:
    if created:
        # Delete only our nonce-named account, after checking it still points at our home.
        record = root_run('/usr/bin/dscl', '.', '-read', account, 'NFSHomeDirectory')
        assert str(home) in record
        subprocess.run(['/usr/bin/pkill', '-u', str(uid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        root_run('/usr/bin/dscl', '.', '-delete', account)
        result['temporaryAccountRemoved'] = True
    shutil.rmtree(workspace)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
raise SystemExit(0 if result['status'] == 'passed' else 1)
