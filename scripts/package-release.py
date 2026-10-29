#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build a reviewable release archive from an already-built, signed Cassini.app."""
import argparse, hashlib, pathlib, shutil, subprocess, tempfile, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('zip', type=pathlib.Path)
args = parser.parse_args()
app, archive = args.app.resolve(), args.zip.resolve()
assert (app / 'Contents/MacOS/cassini-browser-host').is_file(), 'App has no bundled native host'
assert (app / 'Contents/MacOS/cassini-control-host').is_file(), 'App has no bundled control host'
assert (app / 'Contents/XPCServices/CassiniBrowserSetup.xpc').is_dir(), 'App has no browser setup service'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['python3', str(root / 'browser-protocol/verify.py'), '--pinned', str(root / 'BrowserExtension')], check=True)
archive.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='cassini-release-') as temporary:
    stage = pathlib.Path(temporary) / 'Cassini'; stage.mkdir()
    subprocess.run(['ditto', str(app), str(stage / 'Cassini.app')], check=True)
    shutil.copy2(root / 'Distribution/README.txt', stage / 'README.txt')
    shutil.copy2(root / 'COPYING', stage / 'COPYING')
    shutil.copy2(root / 'browser-protocol/PINNED_COMMIT', stage / 'PROTOCOL_COMMIT.txt')
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(stage), str(archive)], check=True)
# Inspect the archive people actually receive, including the licence and fixed
# protocol pin. Developer scripts/extensions remain available in the source repo.
with zipfile.ZipFile(archive) as package:
    names = [name for name in package.namelist() if not name.startswith('__MACOSX/')]
    top = {name.split('/')[1] for name in names if name.startswith('Cassini/') and len(name.split('/')) > 1 and name.split('/')[1]}
    assert top == {'Cassini.app','README.txt','COPYING','PROTOCOL_COMMIT.txt'}, top
    for name, expected in [('COPYING',root/'COPYING'),('PROTOCOL_COMMIT.txt',root/'browser-protocol/PINNED_COMMIT')]:
        assert package.read('Cassini/' + name) == expected.read_bytes(), name
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix(archive.suffix + '.sha256').write_text(checksum + '  ' + archive.name + '\n')
print(archive); print(checksum)
