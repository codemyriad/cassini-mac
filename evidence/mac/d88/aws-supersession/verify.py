from pathlib import Path
import os,subprocess,shutil,sys,difflib,signal
base=Path('/tmp/cassini-aws-d88-before');root=Path('/tmp/cassini-aws-d88-supersession');out=root/'evidence/mac/d88/aws-supersession'
target=base/'Tests/CassiniModelsTests/ModelSupersessionTests.swift';original=target.read_text()
probe=base/'Tests/CassiniModelsTests/SupersessionPoolProbeTests.swift'
helper='/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
binary=Path('/tmp/cassini-aws-d88-before-build/arm64-apple-macosx/debug/CassiniKitPackageTests.xctest/Contents/MacOS/CassiniKitPackageTests')
test_env=dict(os.environ,DYLD_FRAMEWORK_PATH='/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks:/Applications/Xcode_16.4.app/Contents/SharedFrameworks',DYLD_LIBRARY_PATH='/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib:/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx')
strict_env=dict(test_env,LIBDISPATCH_COOPERATIVE_POOL_STRICT='1')
def command(command, log, env, bound):
 with log.open('w') as output:
  process=subprocess.Popen(command,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
  try:return process.wait(timeout=bound)
  except subprocess.TimeoutExpired:
   output.write('\nHANG BOUND: diagnostic process group terminated, no pass claimed\n');output.flush()
   os.killpg(process.pid,signal.SIGKILL);process.wait();return 124
  except BaseException:
   try:os.killpg(process.pid,signal.SIGKILL)
   except ProcessLookupError:pass
   process.wait();raise

def run(label,selected,strict=True,build=True):
 if build:
  rc=command(['swift','build','--build-tests','--package-path',str(base),'--scratch-path','/tmp/cassini-aws-d88-before-build','--jobs','4'],out/(label+'-build.log'),os.environ,300)
  if rc:print(label+' build',rc,flush=True);return rc
 rc=command([helper,'--test-bundle-path',str(binary),str(binary),'--testing-library','swift-testing','--filter',selected],out/(label+'.log'),strict_env if strict else test_env,60)
 print(label,rc,flush=True);return rc
def instrument(source):
 return source.replace('removalLockWaiting:{ waiting.fulfill() }','removalLockWaiting:{ waiting.fulfill(); SupersessionPoolProbeHooks.onLockWait?() }')
try:
 shutil.copyfile(root/'evidence/mac/d88/aws-supersession/pool-probe.swift',probe)
 target.write_text(instrument(original))
 rc=run('before-held-pool','SupersessionPoolProbeTests')
 if rc==0:raise RuntimeError('Held-pool baseline did not expose the dependency')
 if not (out/'before-held-pool.log').exists():raise RuntimeError('Baseline build failed; inspect build log before proceeding')
 log=(out/'before-held-pool.log').read_text()
 if 'ModelSupersessionTests.swift' not in log or 'Expectation failed' not in log:raise RuntimeError('Baseline did not fail the original event assertion; inspect diagnostic')
 target.write_text(instrument((root/'Tests/CassiniModelsTests/ModelSupersessionTests.swift').read_text()))
 if run('after-held-pool','SupersessionPoolProbeTests'):sys.exit(1)
 if run('after-model-supersession','ModelSupersessionTests',False,False):sys.exit(1)
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
