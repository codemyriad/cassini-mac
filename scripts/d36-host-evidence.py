import importlib.util,json,os,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
spec=importlib.util.spec_from_file_location('driver',root/'sdk-source/scripts/test-spectrogram-app.py');driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
output=root/'build/host-evidence';output.mkdir(parents=True,exist_ok=True)
subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
with (output/'B.stderr.txt').open('w') as err,(output/'host.top.txt').open('w') as host:
    process=subprocess.Popen(driver.probe_command(root/'build/native-host.app','B',output),env=dict(os.environ,CASSINI_SPECTRO='1'),stdout=subprocess.PIPE,stderr=err,text=True)
    top=subprocess.Popen(['/usr/bin/top','-l','180','-s','1','-o','cpu','-n','20','-stats','pid,command,cpu,mem'],stdout=host,stderr=subprocess.STDOUT)
    try: stdout,_=process.communicate(timeout=200)
    finally:
        if process.poll() is None:process.kill();process.wait()
        top.terminate();top.wait(timeout=10)
(output/'B.stdout.txt').write_text(stdout)
report=json.loads(stdout);(output/'B.json').write_text(json.dumps(report,indent=2)+'\n')
print({k:report[k] for k in ['gates','maxFrameMs','p95FrameMs','cpuCorePercent','measurementStartMs','measurementEndMs']},flush=True)
assert process.returncode==0
