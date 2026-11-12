#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only preview: user text, Sparkle HTML or GitHub body with folded developers."""
import argparse
import importlib.util
from pathlib import Path
import sys

spec=importlib.util.spec_from_file_location('daily',Path(__file__).with_name('daily-test-release.py'))
daily=importlib.util.module_from_spec(spec);spec.loader.exec_module(daily)
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base',help='Previous published source commit/tag; defaults to latest stable/nightly release')
parser.add_argument('--head',default='HEAD')
parser.add_argument('--developer-head',help='Preview developer history from this ref while fragments come from --head')
parser.add_argument('--format',choices=['text','html','github','sources'],default='text')
args=parser.parse_args()
daily.SOURCE=Path(__file__).resolve().parent.parent
head=daily.command(['git','-C',daily.SOURCE,'rev-parse',args.head+'^{commit}']).strip()
base=args.base
if base is None:
 releases=[r for page in daily.gh(['--paginate','--slurp',f'repos/{daily.REPO}/releases?per_page=100']) for r in page]
 previous=daily.latest_nightly(releases)
 base=daily.source_commit(previous) if previous else daily.stable_notes_base(releases,head)
developer_head=args.developer_head or head
if args.format=='sources':
 print(daily.developer_notes(base,developer_head))
 old=daily.fragment_blobs(base) if base else {}
 for path,blob in daily.fragment_blobs(head).items():
  if old.get(path)!=blob:print(path+'\n'+daily.command(['git','-C',daily.SOURCE,'show',head+':'+path]))
else:
 notes=daily.notes(base,head,include_developer=False)
 if args.format=='github':notes=daily.ReleaseNotes(notes.user,daily.developer_notes(base,developer_head))
 sys.stdout.write(notes.github() if args.format=='github' else notes.html() if args.format=='html' else notes.user+'\n')
