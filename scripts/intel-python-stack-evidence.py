#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Affected fixture suite only; retain timed-out Python state without a PATH override."""
import json,os,shutil,subprocess,select,threading
from pathlib import Path
root=Path(__file__).resolve().parent.parent
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
base=root/'build/intel-python-stack';package=base/'package';target=package/'Tests/ModelsProof'
target.mkdir(parents=True,exist_ok=True)
(package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\n'+
 'let package=Package(name:"PythonStackProof",platforms:[.macOS(.v15)],dependencies:[.package(path:'+json.dumps(str(root))+')],targets:[.testTarget(name:"ModelsProof",dependencies:[.product(name:"CassiniModels",package:'+json.dumps(root.name)+')],resources:[.copy("Fixtures")])])\n')
shutil.copyfile(root/'Tests/CassiniModelsTests/ModelDownloaderTests.swift',target/'ModelDownloaderTests.swift')
shutil.copytree(root/'Tests/CassiniModelsTests/Fixtures',target/'Fixtures',dirs_exist_ok=True)
subprocess.run(['swift','build','--build-tests','-j','2','--package-path',str(package)],check=True)
children=base/'children';children.mkdir(exist_ok=True)
env=dict(os.environ,CASSINI_FIXTURE_DIAGNOSTICS=str(children))
ready=threading.Event();finished=threading.Event();owner={}
def observe_parent():
    # One filesystem event, not a timed poll: the first Python child has
    # registered its native stack handler and is entering HTTP imports.
    fd=os.open(children,os.O_RDONLY);queue=select.kqueue()
    try:
        queue.control([select.kevent(fd,filter=select.KQ_FILTER_VNODE,flags=select.KQ_EV_ADD|select.KQ_EV_CLEAR,fflags=select.KQ_NOTE_WRITE)],0)
        ready.set()
        while not finished.is_set():
            if not queue.control(None,1,20):
                if not finished.is_set():(base/'parent-observer.txt').write_text('No child registration event before diagnostic bound')
                return
            for marker in children.glob('*.python-handler-ready'):
                try:
                    child=int(marker.name.split('.')[0]);parent=int(subprocess.check_output(['/bin/ps','-p',str(child),'-o','ppid='],text=True))
                    ancestor=parent
                    for _ in range(8):
                        if ancestor==owner.get('pid'):break
                        ancestor=int(subprocess.check_output(['/bin/ps','-p',str(ancestor),'-o','ppid='],text=True))
                    else:continue
                    (base/'parent-observer.json').write_text(json.dumps({'pythonChild':child,'testParent':parent,'ownedCLI':owner['pid']},indent=2)+'\n')
                    with (base/'parent-process.txt').open('w') as output:
                        subprocess.run(['/bin/ps','-p',str(parent),'-o','pid=,ppid=,state=,etime=,time=,comm='],stdout=output,stderr=subprocess.STDOUT,timeout=5)
                    with (base/'parent-sample.log').open('w') as output:
                        subprocess.run(['/usr/bin/sample',str(parent),'1','10','-file',str(base/'parent-stack.txt')],stdout=output,stderr=subprocess.STDOUT,timeout=8)
                    return
                except (OSError,ValueError,subprocess.SubprocessError) as error:
                    (base/'parent-observer-error.txt').write_text(str(error))
    finally:queue.close();os.close(fd)
observer=threading.Thread(target=observe_parent,daemon=True);observer.start()
assert ready.wait(timeout=5),'Observer did not register'
with (base/'tests.log').open('w') as output:
    process=subprocess.Popen(['swift','test','--skip-build','--package-path',str(package),'--filter','ModelDownloaderTests'],env=env,stdout=output,stderr=subprocess.STDOUT)
    owner['pid']=process.pid
    try:status=process.wait(timeout=120)
    finally:
        if process.poll() is None:process.kill();process.wait()
        finished.set()
observer.join(timeout=25)
print((base/'tests.log').read_text())
raise SystemExit(status)
