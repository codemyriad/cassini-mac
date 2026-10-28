#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private app proof: only the download XPC service has networking; workers do not."""
import argparse,json,os,plistlib,socketserver,subprocess,threading,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('app',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
hosted=os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert hosted or os.environ.get('CASSINI_LOCAL_WORKFLOW_TESTS')=='1','Explicit workflow opt-in required'
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(a.app.resolve())],capture_output=True,check=True)
profile=plistlib.loads(signed.stdout)
expected=plistlib.loads((Path(__file__).resolve().parent.parent/'Cassini/Cassini.entitlements').read_bytes())
assert profile==expected and not profile.get('com.apple.security.network.client'),'Use the exact product profile without network access'
service=a.app/'Contents/XPCServices/CassiniModelDownloads.xpc'
service_profile=plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(service)],capture_output=True,check=True).stdout)
assert service_profile==plistlib.loads((Path(__file__).resolve().parent.parent/'ModelDownloads/ModelDownloads.entitlements').read_bytes()),'Use the exact download-service product profile'
class Handler(socketserver.BaseRequestHandler):
    def handle(self):pass
with socketserver.TCPServer(('127.0.0.1',0),Handler) as server:
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    key=str(uuid.uuid4())
    command=[str(a.app.resolve()/'Contents/MacOS/Cassini'),'--models-network-self-test',str(server.server_address[1]),
             '-CassiniSettingsID',key,'-CassiniCaptureID',key,'-ApplePersistenceIgnoreState','YES']
    result=subprocess.run(command,env=dict(os.environ,CASSINI_HOSTED_SCREENSHOTS='1'),capture_output=True,text=True,timeout=45)
    server.shutdown();thread.join(timeout=5)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.with_suffix('.stderr.txt').write_text(result.stderr)
assert result.returncode==0,(result.returncode,result.stdout,result.stderr)
report=json.loads(result.stdout)
assert report['downloadServiceConnected'] is True and report['scopedModelDirectory'] is True
assert report['workersNetworkDenied']=={'cassini-parakeet-worker':True,'cassini-whistle-worker':True}
assert report['audioDevicesOpened'] is False
a.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS signed app: download XPC network and scoped model-directory grants; both inference workers denied network')
