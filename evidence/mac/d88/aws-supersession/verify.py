from pathlib import Path
import os,subprocess,shutil,sys,difflib
base=Path('/tmp/cassini-aws-d88-before');root=Path('/tmp/cassini-aws-d88-supersession');out=root/'evidence/mac/d88/aws-supersession'
target=base/'Tests/CassiniModelsTests/ModelSupersessionTests.swift';original=target.read_text()
probe=base/'Tests/CassiniModelsTests/SupersessionPoolProbeTests.swift'
env=dict(os.environ,LIBDISPATCH_COOPERATIVE_POOL_STRICT='1')
def run(label,selected,strict=True):
 with (out/(label+'.log')).open('w') as log:
  rc=subprocess.call(['swift','test','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4','--filter',selected],env=env if strict else os.environ,stdout=log,stderr=subprocess.STDOUT)
 print(label,rc,flush=True);return rc
try:
 shutil.copyfile('/tmp/SupersessionPoolProbeTests.swift',probe)
 if run('before-held-pool','SupersessionPoolProbeTests')==0:raise RuntimeError('Held-pool baseline did not expose the dependency')
 shutil.copyfile(root/'Tests/CassiniModelsTests/ModelSupersessionTests.swift',target)
 if run('after-held-pool','SupersessionPoolProbeTests'):sys.exit(1)
 if run('after-model-supersession','ModelSupersessionTests',False):sys.exit(1)
 prod=base/'Sources/CassiniModels/ModelDownloader.swift';saved=prod.read_text();changed=saved.replace('try Self.validateInstalled(directory,plan:replacement,verifyHashes:true)','// MUTATION: omit replacement hash revalidation')
 assert changed!=saved
 prod.write_text(changed)
 (out/'skip-revalidation.patch').write_text(''.join(difflib.unified_diff(saved.splitlines(True),changed.splitlines(True),fromfile='a/Sources/CassiniModels/ModelDownloader.swift',tofile='b/Sources/CassiniModels/ModelDownloader.swift')))
 try:
  if run('skip-revalidation','ModelSupersessionTests.replacementIsRecheckedAfterItsLockAndCancellationKeepsOld',False)==0:raise RuntimeError('Mutation survived')
 finally:prod.write_text(saved)
 if run('restored','ModelSupersessionTests|SupersessionPoolProbeTests'):sys.exit(1)
finally:
 target.write_text(original)
 if probe.exists():probe.unlink()
