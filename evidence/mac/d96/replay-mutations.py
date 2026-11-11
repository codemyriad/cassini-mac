from pathlib import Path
import difflib,json,subprocess,signal,os
root=Path(__file__).resolve().parents[3]
ev=Path(os.environ['D96_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (ev,*ev.parents), 'Use external evidence'
ev.mkdir(parents=True,exist_ok=True)
out=ev/'public-mutations';out.mkdir(parents=True,exist_ok=True)
build=ev/'build'
swift=['swift','test','--scratch-path',str(build),'--jobs','4']
# Cancel safely between mutations; each operation restores in finally.
signal.signal(signal.SIGTERM,lambda *_:(_ for _ in ()).throw(KeyboardInterrupt()))
Z='Sources/CassiniKit/ZIPArchive.swift';L='Sources/CassiniLibrary/LibraryBulkImport.swift'
cases=[
 ('unsafe-paths','unsafePathsAreRejected|refusedArchivesPublishNoMember',[(Z,'!name.split(separator: "/").contains("..")','true')]),
 ('entry-count','refusedArchivesPublishNoMember',[(Z,'count <= UInt64(max(0, limits.entries))','true')]),
 ('ratio','refusedArchivesPublishNoMember',[(Z,'expanded == 0 || (ratio > 0 && compressed > 0 && (expanded - 1) / ratio < compressed)','true')]),
 ('crc','corruptOrIndividuallyOversizedMembersDoNotDiscardGoodMembers',[(Z,'checksum == entry.checksum','true')]),
 ('runtime-budget','actualByteBudgetAndEmptyArchivesAreReported',[(Z,'UInt64(data.count) <= remainingBytes - bytes','true'),(L,'UInt64(count) <= limits.expandedBytes - observed','true')]),
 ('dedup','supportedMembersUseOrdinaryDedupAndPreserveNames',[('Sources/CassiniLibrary/LibraryImport.swift','return LibraryImportResult(meeting:duplicate,duplicate:true)','continue')]),
 ('selected-completeness','cancellationAndMissingSelectionMemberRemovePartialArchive',[('Sources/CassiniExport/MeetingArchiveExporter.swift','guard let meeting=current, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty else { throw MeetingExportError.invalidSource }','guard let meeting=current, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty else { continue }')]),
 ('chunk-cancellation','limitsAndCancellationAreCheckedDuringStreaming',[]),
 ('local-title','renamedPlainAudioKeepsItsTitleAndAudioOnAnotherImport|completeDocumentsKeepWordsAndNewNotesWhileOpaqueFilesKeepEveryByte',[('Sources/CassiniExport/MeetingArchiveExporter.swift','let titleEdited = stored?["titleSource"]?.string == "user"','let titleEdited = false')]),
]
results=[]
for name,test,edits in cases:
 originals={}
 try:
  for file,old,new in edits:
   p=root/file;originals.setdefault(file,p.read_text());s=p.read_text();assert s.count(old)==1,(name,file)
   p.write_text(s.replace(old,new))
  if name=='chunk-cancellation':
   p=root/Z;s=p.read_text();originals[Z]=s;a=s.index('@discardableResult public func read(');b=s.index('    static func checkPath',a)
   assert 'try check()' in s[a:b];p.write_text(s[:a]+s[a:b].replace('try check()','')+s[b:])
  patch=''.join(''.join(difflib.unified_diff(old.splitlines(True),(root/file).read_text().splitlines(True),fromfile='a/'+file,tofile='b/'+file,n=0)) for file,old in originals.items())
  (out/(name+'.patch')).write_text(patch)
  log=ev/('mutation-'+name+'.log')
  with log.open('w') as stream:
   result=subprocess.run(swift+['--filter',test],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=240)
  text=log.read_text();failures=[line.replace(str(root),'<checkout>') for line in text.splitlines() if 'recorded an issue' in line]
  assert result.returncode!=0 and failures and 'Asynchronous wait failed' not in text and 'error: fatalError' not in text,(name,result.returncode)
  results.append({'case':name,'test':test,'failure':failures[0]});print(name,'fails behavioral assertion',flush=True)
 finally:
  for file,original in originals.items():(root/file).write_text(original)
with (ev/'restored.log').open('w') as stream:
 subprocess.run(swift+['--filter','ZIPArchiveTests|BulkImportTests|BulkExportTests'],cwd=root,stdout=stream,stderr=subprocess.STDOUT,check=True,timeout=240)
(out/'mutations.json').write_text(json.dumps(results,indent=2)+'\n')
print('restored core tests pass',flush=True)
