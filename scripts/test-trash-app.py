#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Actual sandbox Trash/Undo and Finder Put Back with isolated hosted files."""
import argparse, hashlib, json, os, plistlib, subprocess, tempfile, uuid
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('app',type=Path);p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted','Hosted disposable runner only'
root=Path(__file__).resolve().parent.parent
entitlements=subprocess.run(['codesign','-d','--entitlements',':-',str(a.app.resolve())],capture_output=True,check=True)
assert plistlib.loads(entitlements.stdout)==plistlib.loads((root/'Cassini/Cassini.entitlements').read_bytes()),'Production sandbox required'
key=str(uuid.uuid4()).upper()
music=Path.home()/'Music';music.mkdir(exist_ok=True)
config=music/f'CassiniTrashBookmark-{key}.json'
putback=music/f'CassiniTrashPutBack-{key}.json'
external=Path(tempfile.mkdtemp(prefix='cassini-trash-external-',dir=root/'build'))
# Use Apple’s implicit bookmark IPC handoff. Cassini resolves it and creates
# its own app-scoped persistent bookmark; app-scoped bookmarks cannot be
# shared between differently signed processes. No sandbox entitlement is added.
helper=external/'bookmark.swift'
helper.write_text('''import Foundation
let url = URL(fileURLWithPath:CommandLine.arguments[1])
let data = try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
print(data.base64EncodedString())
''')
bookmark=subprocess.check_output(['swift',str(helper),str(external)],text=True).strip()
config.write_text(json.dumps(dict(handoff=bookmark)))
command=[str(a.app.resolve()/'Contents/MacOS/Cassini'),'--trash-self-test','--fixture-library-recording',
         '-CassiniCaptureID',key,'-CassiniSettingsID',key,'-CassiniTrashRelocationFile',str(config),
         '-CassiniTranscriptionFixture','YES','-CassiniSlowTranscription','YES','-ApplePersistenceIgnoreState','YES']
env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1')
a.output.parent.mkdir(parents=True,exist_ok=True)
def run(args,label):
    result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=90)
    a.output.with_suffix(f'.{label}.stderr.txt').write_text(result.stderr)
    assert result.returncode==0,(result.returncode,result.stdout,result.stderr)
    return json.loads(result.stdout)
report=run(command,'trash')
a.output.with_suffix('.before-putback.json').write_text(json.dumps(report,indent=2)+'\n')
for name in ['ok','queuedCancelIsPerMeeting','activeCancelWaitsForChild','hiddenEditsDiscarded','meetingAndExportClosed',
             'failurePreservesSourceAndRetry','unrelatedMetadataDoesNotDelayTrash','pendingMoveDiscarded','primaryAndBookmarkedTrash','sandboxUndoVerifiedOrAbsent']:
    assert report[name] is True,(name,report)
assert report['audioDevicesOpened'] is False
assert {c['kind'] for c in report['sandboxCases']}=={'music','bookmark'}
# Simulate Finder Put Back outside the app, then prove the actual sandboxed
# scanner sees both unmodified meetings. Never restore over an existing item.
for case in report['sandboxCases']:
    source=Path(case['trashed']);destination=Path(case['original'])
    assert source.is_dir() and not destination.exists(),case
    assert hashlib.sha256((source/'session.json').read_bytes()).hexdigest()==case['sessionSHA256']
    os.rename(source,destination)
putback.write_text(json.dumps(report))
resume=command.copy();resume[resume.index('-CassiniTranscriptionFixture')+1]='NO'
restored=run(resume+['-CassiniTrashPutBackFile',str(putback)],'putback')
assert restored==dict(finderPutBackRescan=True,audioDevicesOpened=False),restored
report.update(restored);a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS actual Music/bookmarked sandbox Trash, conditional Undo, independent cancellation, hidden saves, retry and Put Back')
