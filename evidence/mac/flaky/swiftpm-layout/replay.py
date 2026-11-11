#!/usr/bin/env python3
"""Use a disposable worktree; the committed workflow mutation restores in finally."""
from pathlib import Path
import os,subprocess,json
root=Path(__file__).resolve().parents[4]
ev=Path(os.environ['CASSINI_ABI_EVIDENCE']).expanduser().resolve();ev.mkdir(parents=True,exist_ok=True)
workflow=root/'.github/workflows/ci-build.yml';fixed=workflow.read_bytes()
def run(name,fail=False):
 folder=ev/name
 result=subprocess.run(['python3',str(Path(__file__).with_name('probe.py'))],cwd=root,env=dict(os.environ,CASSINI_ABI_EVIDENCE=str(folder)))
 report=json.loads((folder/'result.json').read_text())
 if fail:assert result.returncode!=0 and report['crossSourceCacheRestored'] and report['nativeClientExit']==-10,report
 else:assert result.returncode==0 and not report['crossSourceCacheRestored'] and report['nativeClientExit']==0,report
run('fixed')
try:
 patch=Path(__file__).with_name('restore-prefix.patch')
 subprocess.run(['git','apply','--check',str(patch)],cwd=root,check=True)
 subprocess.run(['git','apply',str(patch)],cwd=root,check=True)
 run('mutation',True)
finally:workflow.write_bytes(fixed)
run('restored')
