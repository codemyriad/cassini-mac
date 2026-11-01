#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One hosted, paired pill layout check. Never changes capture, clock or budgets."""
import json, os, subprocess, sys
from pathlib import Path
if os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted':raise SystemExit('Hosted Mac only')
output=Path(sys.argv[3]);output.mkdir(parents=True,exist_ok=True);reports=[]
old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
try:
 subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
 for label,program,case in [('control',sys.argv[1],'A'),('shared-parent',sys.argv[2],'A'),('shared-parent',sys.argv[2],'B')]:
  folder=output/(label+'-'+case);folder.mkdir()
  command=[str(Path(program).resolve()),'--spectrogram-self-test','-SpectrogramCase',case,'-SpectrogramOutput',str(folder.resolve()),'-ApplePersistenceIgnoreState','YES']
  if case=='B':command+=['-SpectrogramPixelsOnly','1']
  with (folder/'stderr.txt').open('w') as stderr:
   run=subprocess.run(command,stdout=subprocess.PIPE,stderr=stderr,text=True,timeout=120,env=dict(os.environ,CASSINI_SPECTRO='1'))
  (folder/'stdout.txt').write_text(run.stdout)
  report=json.loads(run.stdout);report.update(variant=label,exitStatus=run.returncode);reports.append(report)
  (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n')
  print(label,case,'draw',report.get('drawingCorePercent'),'analysis',report.get('analysisCorePercent'),'gates',report.get('gates'),'pill',report.get('pillCompositedInkPixels'),flush=True)
finally:
 command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
 subprocess.run(command,capture_output=True)
 (output/'summary.json').write_text(json.dumps({'measurements':reports,'scope':'Paired exact production control vs one shared pill parent. Same verified Release SDK, NSView display link, cadence, PCM and budgets. B adds real per-lane pill sound/silence pixels; ends before later state/motion phases. This never replaces full product CI.'},indent=2)+'\n')
if any(r.get('exitStatus') for r in reports) or any(not all(r['gates'].values()) for r in reports if r['variant']=='shared-parent'):raise SystemExit('Candidate gate or native pixels failed')
