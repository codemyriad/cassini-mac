#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One hosted diagnostic of the existing pill; no renderer or gate change."""
import gzip, importlib.util, json, os
from pathlib import Path
import subprocess, sys
if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('Disposable GitHub-hosted Mac required')
module_path=Path(__file__).with_name('test-spectrogram-app.py')
spec=importlib.util.spec_from_file_location('spectrogram_probe',module_path)
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
original=probe.probe_command
probe.probe_command=lambda app,case,output,**options:original(app,'A',output,**options)
output=Path(sys.argv[2]);output.mkdir(parents=True,exist_ok=True)
old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
try:
    subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
    assert probe.record_profile(Path(sys.argv[1]),output)
    trace=output/'B-TimeProfiler.trace'
    with (output/'profile-toc.xml').open('wb') as f:
        subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--toc'],stdout=f,check=True)
    with gzip.open(output/'pill-profile.xml.gz','wb') as f:
        subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--xpath','/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],stdout=f,check=True)
    (output/'scope.json').write_text(json.dumps({'case':'A','rendererCommit':'8aebea3','sdkSource':'6e940e8 (same Sources bytes as 8aebea3)','diagnosticOnly':True,'nativeDevices':False,'CVClock':False})+'\n')
finally:
    command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
    subprocess.run(command,capture_output=True)
