#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build and inspect a tiny DMG with inert files; never execute an app or Finder."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT/'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

INSPECT_LAYOUT = '''from ds_store import DSStore
import sys, json
with DSStore.open(sys.argv[1], 'r') as store:
    assert store['.']['icvp']['backgroundType'] == 2
    assert store['.']['icvp']['backgroundImageAlias']
    assert store['Cassini talk.app']['Iloc'] == (140, 120)
    assert store['Applications']['Iloc'] == (500, 120)
    assert store['COPYING']['Iloc'] == (320, 280)
    assert store['.']['bwsp']['WindowBounds'] == '{{100, 300}, {640, 400}}'
    options=store['.']['icvp']
    for name in ['Cassini talk.app','Applications','COPYING']:
        x,y=store[name]['Iloc']
        assert x-options['iconSize']/2 >= 0 and x+options['iconSize']/2 <= 640
        assert y+options['iconSize']/2+2*options['textSize']+22 <= 400
    print(json.dumps(dict(backgroundMetadata=True, applicationPosition=store['Cassini talk.app']['Iloc'],
                         applicationsPosition=store['Applications']['Iloc'])))
'''


def main():
    python = release.dmg_tools()
    with tempfile.TemporaryDirectory(prefix='cassini-d34-dmg-fixture-') as temporary:
        root = Path(temporary)
        app = root/'Cassini talk.app'
        (app/'Contents').mkdir(parents=True)
        info = app/'Contents/Info.plist'
        info.write_bytes(plistlib.dumps(dict(CFBundleName='Cassini talk', CFBundleIdentifier='io.codemyriad.cassini')))
        image = root/'fixture.dmg'
        release.build_dmg(python, app, image)
        mount = root/'mount'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, image], check=True, capture_output=True)
        try:
            assert (mount/app.name/'Contents/Info.plist').read_bytes() == info.read_bytes()
            assert (mount/'Applications').is_symlink() and (mount/'Applications').readlink() == Path('/Applications')
            assert (mount/'COPYING').read_bytes() == (ROOT/'COPYING').read_bytes()
            assert (mount/'.dmgbuild-LICENSE.txt').read_bytes() == (ROOT/'Distribution/dmgbuild-LICENSE.txt').read_bytes()
            background=(mount/'.background/background.png').read_bytes()
            assert background.startswith(b'\x89PNG\r\n\x1a\n')
            assert struct.unpack('>II',background[16:24]) == (640,400)
            result = subprocess.run([python, '-c', INSPECT_LAYOUT, mount/'.DS_Store'], check=True, capture_output=True, text=True)
            print(result.stdout.strip())
        finally:
            subprocess.run(['hdiutil', 'detach', mount], check=True, capture_output=True)
    print('PASS private DMG fixture: final app name, background file/metadata, unclipped icon bounds, Applications link and licences; Finder rendering requires the separate QA guest')


if __name__ == '__main__':
    main()
