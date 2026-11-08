#!/usr/bin/env python3
"""Targeted native A-E proof; full product CI retains motion/allocations/profiling."""
import importlib.util,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def verify():
    for name in ['Sources/CassiniSpectrogram','Sources/CassiniRecording','Sources/CassiniBrowserControl','Sources/CassiniLibrary','Sources/CassiniKit','Cassini/Recording/RecordingSpectrogram.swift','Spikes/Spectrogram/Budget.swift','Tests/CassiniRecordingTests/SpectrogramFixtureClock.swift']:
        source=ROOT/name
        paths=sorted(p for p in source.rglob('*') if p.is_file()) if source.is_dir() else [source]
        for path in paths:assert path.read_bytes()==(ROOT/'sdk-source'/path.relative_to(ROOT)).read_bytes(),path
    print('Every linked SDK source and production renderer matches the verified producer; only the fixture timer changed.')

def run():
    assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
    output=ROOT/'build/d36-evidence';output.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('driver',ROOT/'scripts/test-spectrogram-app.py');driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
    old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
    problems=[]
    try:
        for case in 'ABCDE':
            subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
            process=top=None
            with (output/f'{case}.stderr.txt').open('w') as errors,(output/f'{case}.top.txt').open('w') as top_log:
                try:
                    process=subprocess.Popen(driver.probe_command(ROOT/'build/d36-evidence.app',case,output),env=dict(os.environ,CASSINI_SPECTRO='0' if case=='E' else '1'),stdout=subprocess.PIPE,stderr=errors,text=True)
                    top=subprocess.Popen(['/usr/bin/top','-l','90','-s','1','-pid',str(process.pid),'-stats','pid,cpu'],stdout=top_log,stderr=subprocess.STDOUT)
                    stdout,_=process.communicate(timeout=200 if case=='B' else 85)
                finally:
                    if process and process.poll() is None:process.kill();process.wait()
                    if top:top.terminate();top.wait(timeout=10)
            (output/f'{case}.stdout.txt').write_text(stdout)
            report=json.loads(stdout);(output/f'{case}.json').write_text(json.dumps(report,indent=2)+'\n')
            if process.returncode or not all(report['gates'].values()) or report['reducedMotion'] or report['audioDevicesOpened'] or not report['stopDisconnectsAndFreezes'] or not report['detachReleasesSurfaces']:problems.append(case)
            if case=='B' and (not report['hideShowReleasesAndRestarts'] or report['liveCompositedInkPixels']['sound']<100 or report['liveCompositedInkPixels']['silence']>4):problems.append('B lifecycle')
            print(json.dumps({k:report[k] for k in ['case','gates','lateColumns','steadyStateColumns','cpuCorePercent','analysisCorePercent','drawingCorePercent','p95FrameMs','maxFrameMs']}),flush=True)
        if problems:raise SystemExit('Targeted A-E failure: '+', '.join(problems))
    finally:
        command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
        subprocess.run(command,check=True)

if sys.argv[1:]==['verify']:verify()
elif sys.argv[1:]==['run']:run()
else:raise SystemExit('Expected verify or run')
