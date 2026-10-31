#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create installer metadata without running Finder on the build machine."""
import argparse
import subprocess
from pathlib import Path
import dmgbuild
from ds_store import DSStore
from mac_alias import Alias

ROOT=Path(__file__).resolve().parent.parent


class FinderBookmark:
    """DSStore's pBBk codec accepts bookmark objects exposing to_bytes()."""
    def __init__(self, data):
        self.data = data

    def to_bytes(self):
        return self.data


def build(application,output):
    mounted=None
    def created(path,options):
        nonlocal mounted
        mounted=Path(path)
    def progress(event):
        if event.get('operation')!='dsstore::create' or event.get('type')!='operation::finished':return
        # Keep the picture in a conventional hidden folder and construct its
        # references at the final location before the image becomes read-only.
        folder=mounted/'.background';folder.mkdir()
        picture=folder/'background.png';(mounted/'.background.png').rename(picture)
        with DSStore.open(str(mounted/'.DS_Store'),'r+') as store:
            options=store['.']['icvp']
            options['backgroundType']=2
            options['backgroundImageAlias']=Alias.for_file(str(picture)).to_bytes()
            store['.']['icvp']=options
            # Finder rejected the Python-generated bookmark in fresh guest
            # mounts, although URL resolution alone passed. Foundation creates
            # the bookmark used by Finder, without opening any application.
            bookmark = subprocess.check_output([
                'xcrun', 'swift', str(ROOT/'scripts/dmg-background-bookmark.swift'), str(picture)])
            store['.']['pBBk'] = FinderBookmark(bookmark)
    dmgbuild.build_dmg(str(output),'Cassini talk',settings_file=str(ROOT/'Distribution/dmg-settings.py'),
        settings={'create_hook':created},defines={'app':str(application),'license':str(ROOT/'COPYING'),
        'background_license':str(ROOT/'Distribution/dmgbuild-LICENSE.txt'),'background':str(ROOT/'Distribution/dmg-background.png')},callback=progress)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();build(args.app,args.output)
