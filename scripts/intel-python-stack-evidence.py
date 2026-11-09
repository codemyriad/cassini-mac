#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Affected fixture suite only; retain timed-out Python state without a PATH override."""
import json,os,shutil,subprocess
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
env=dict(os.environ,CASSINI_FIXTURE_DIAGNOSTICS=str(base/'children'))
with (base/'tests.log').open('w') as output,(base/'host.top.txt').open('w') as host:
    top=subprocess.Popen(['/usr/bin/top','-l','180','-s','1','-o','cpu','-n','20','-stats','pid,command,cpu,mem'],stdout=host,stderr=subprocess.STDOUT)
    try:result=subprocess.run(['swift','test','--skip-build','--package-path',str(package),'--filter','ModelDownloaderTests'],env=env,stdout=output,stderr=subprocess.STDOUT)
    finally:top.terminate();top.wait(timeout=10)
print((base/'tests.log').read_text())
raise SystemExit(result.returncode)
