#!/usr/bin/env python3
"""Register only existing browser installations. No passwords or account access."""
import json
import pathlib
import sys

support = pathlib.Path.home() / 'Library/Application Support'
remove = sys.argv[1:] == ['--uninstall']
if not remove:
    extension_id, executable = sys.argv[1:]
    executable = str(pathlib.Path(executable).resolve(strict=True))
    manifest = dict(name='com.codemyriad.cassini', description='Cassini local meeting recorder', path=executable,
                    type='stdio', allowed_origins=[f'chrome-extension://{extension_id}/'])
changed = 0
for browser in ['Google/Chrome', 'Chromium', 'Microsoft Edge', 'BraveSoftware/Brave-Browser']:
    base = support / browser
    if not base.is_dir():
        continue
    directory = base / 'NativeMessagingHosts'
    destination = directory / 'com.codemyriad.cassini.json'
    if remove:
        if destination.exists():
            destination.unlink(); changed += 1
    else:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination.write_text(json.dumps(manifest, indent=2) + '\n')
        destination.chmod(0o600); changed += 1
if remove:
    owned = support / 'Cassini/BrowserHost/cassini-browser-host'
    if owned.is_file(): owned.unlink()
    print(f'Removed {changed} Cassini browser registrations. Recordings were retained.')
else:
    print(f'Registered Cassini in {changed} existing browser directories. Recordings: ~/Music/Cassini.')
    if not changed: print('Open your browser once, then rerun this installer.')
