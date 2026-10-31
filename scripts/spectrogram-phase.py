#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Short hosted-only real CA-position check; no CPU gate or budget substitution."""
import json,os,subprocess,sys
from pathlib import Path
if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('Disposable GitHub-hosted Mac required')
output=Path(sys.argv[3]);output.mkdir(parents=True,exist_ok=True)
old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
reports=[]
try:
    subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
    for label,program in zip(['surface-contents','timed-layer'],sys.argv[1:3],strict=True):
        for mode in 'ADB':
            result=subprocess.run([str(Path(program).resolve()),'--spectrogram-self-test','-SpectrogramCase',mode,
                '-SpectrogramPhaseOnly','1','-ApplePersistenceIgnoreState','YES'],capture_output=True,text=True,timeout=30)
            (output/(label+'-'+mode+'.stderr')).write_text(result.stderr)
            (output/(label+'-'+mode+'.stdout')).write_text(result.stdout)
            report=json.loads(result.stdout);report.update(variant=label,case=mode,exitStatus=result.returncode)
            reports.append(report)
            print(label,mode,report,flush=True)
finally:
    command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
    subprocess.run(command,capture_output=True)
    (output/'summary.json').write_text(json.dumps({'measurements':reports,'scope':'Real CA presentation positions across fifteen actual display frames. Independent of CPU duration measurement, no budget exemption.'},indent=2)+'\n')
if len(reports) != 6 or any(r['exitStatus'] != 0 or not r.get('positionsMatchDisplayClock') for r in reports):
    raise SystemExit('Scrolling phase proof failed')
