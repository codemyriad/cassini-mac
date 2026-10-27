#!/usr/bin/env python3
"""Build a reviewable release archive from an already-built, signed Cassini.app."""
import argparse, hashlib, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('zip', type=pathlib.Path)
args = parser.parse_args()
app, archive = args.app.resolve(), args.zip.resolve()
assert (app / 'Contents/MacOS/cassini-browser-host').is_file(), 'App has no bundled native host'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['python3', str(root / 'browser-protocol/verify.py'), '--pinned', str(root / 'BrowserExtension')], check=True)
archive.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='cassini-release-') as temporary:
    stage = pathlib.Path(temporary) / 'Cassini'; stage.mkdir()
    subprocess.run(['ditto', str(app), str(stage / 'Cassini.app')], check=True)
    shutil.copytree(root / 'BrowserExtension', stage / 'BrowserExtension', ignore=shutil.ignore_patterns('tests', 'node_modules', '.DS_Store'))
    for name in ['Install Browser Host.command', 'README.txt']: shutil.copy2(root / 'Distribution' / name, stage / name)
    shutil.copy2(root / 'browser-protocol/PINNED_COMMIT', stage / 'PROTOCOL_COMMIT.txt')
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(stage), str(archive)], check=True)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix(archive.suffix + '.sha256').write_text(checksum + '  ' + archive.name + '\n')
print(archive); print(checksum)
