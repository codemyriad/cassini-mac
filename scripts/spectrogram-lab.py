#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Temporary branch-only A/D CPU experiment. No local native-view execution."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
if os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted':
 raise SystemExit('Disposable GitHub-hosted Mac required')
output=Path(sys.argv[3]);output.mkdir(parents=True,exist_ok=True)
reports=[]
old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
try:
 subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
 for label,program in zip(['baseline','hosting-no-poll'],sys.argv[1:3],strict=True):
  source=Path(program).parent/'Cassini/Recording/RecordingSpectrogram.swift'
  for mode in 'AD':
   name=label+'-'+mode
   with (output/(name+'.stderr')).open('w') as error,(output/(name+'.top')).open('w') as top:
    app=subprocess.Popen([str(Path(program).resolve()),'--spectrogram-self-test','-SpectrogramCase',mode,'-SpectrogramOutput',str(output.resolve()),'-ApplePersistenceIgnoreState','YES'],stdout=subprocess.PIPE,stderr=error,text=True)
    sampler=subprocess.Popen(['/usr/bin/top','-l','80','-s','1','-pid',str(app.pid),'-stats','pid,cpu'],stdout=top,stderr=subprocess.STDOUT)
    try:stdout,_=app.communicate(timeout=85)
    finally:
     if app.poll() is None:app.kill();app.wait()
     sampler.terminate();sampler.wait(timeout=10)
   (output/(name+'.stdout')).write_text(stdout)
   report=json.loads(stdout);report['variant']=label;report['exitStatus']=app.returncode
   report['rendererSHA256']=hashlib.sha256(source.read_bytes()).hexdigest()
   reports.append(report)
   (output/(name+'.json')).write_text(json.dumps(report,indent=2)+'\n')
   print(label,mode,'analysis',report.get('analysisCorePercent'),'draw',report.get('drawingCorePercent'),'late',report.get('lateColumns'),'gates',report.get('gates'),flush=True)
finally:
 command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
 subprocess.run(command,capture_output=True)
 (output/'summary.json').write_text(json.dumps({'measurements':reports,'scope':'Experiment only. Source-bound previously built SDK; same actual A/D producer, renderer and unchanged budget gates. No app/SDK rebuild or local execution. Does not replace full A–E/visual/allocation/production CI.'},indent=2)+'\n')
if any(r.get('exitStatus') or not all(r.get('gates',{}).values()) for r in reports):
 raise SystemExit('Experiment retains failed budget gates; inspect per-variant reports')
