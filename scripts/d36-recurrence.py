import importlib.util,json,os,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
spec=importlib.util.spec_from_file_location('driver',root/'scripts/test-spectrogram-app.py');driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
output=root/'build/d36-evidence';output.mkdir(parents=True,exist_ok=True)
old=subprocess.run(['defaults','read','com.apple.universalaccess','reduceMotion'],capture_output=True,text=True)
try:
    subprocess.run(['defaults','write','com.apple.universalaccess','reduceMotion','-bool','false'],check=True)
    for qos in ['unspecified','userInitiated']:
        folder=output/qos;folder.mkdir(exist_ok=True)
        with (folder/'stderr.txt').open('w') as err:
            result=subprocess.run(driver.probe_command(root/'build/d36-evidence.app','D',folder),env=dict(os.environ,CASSINI_SPECTRO='1',CASSINI_SOURCE_QOS=qos),capture_output=False,stdout=subprocess.PIPE,stderr=err,text=True,timeout=100)
        (folder/'stdout.txt').write_text(result.stdout)
        assert result.returncode==0,result.returncode
        report=json.loads(result.stdout);(folder/'D.json').write_text(json.dumps(report,indent=2)+'\n')
        print(qos,{key:report[key] for key in ['gates','lateColumns','steadyStateColumns','displayDelayMs']},flush=True)
finally:
    command=['defaults','write','com.apple.universalaccess','reduceMotion','-bool','true' if old.stdout.strip()=='1' else 'false'] if old.returncode==0 else ['defaults','delete','com.apple.universalaccess','reduceMotion']
    subprocess.run(command,check=True)
