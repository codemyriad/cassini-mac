#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Import a returned certificate into an isolated local signing keychain; no app runs."""
from pathlib import Path
import subprocess,secrets,os,json,re,tempfile
folder=Path.home()/'.config/cassini/secrets';kc=folder/'cassini-signing.keychain-db';pwfile=folder/'cassini-signing-keychain.password'
def run(command):
 r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
 if r.returncode:raise RuntimeError('Signing keychain operation failed: '+command[1]+'; exit '+str(r.returncode))
 return r.stdout
if not pwfile.exists():
 fd=os.open(pwfile,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:f.write(secrets.token_urlsafe(48))
pw=pwfile.read_text();pwfile.chmod(0o600)
a=run(['openssl','x509','-inform','DER','-in',str(folder/'developerID_application.cer'),'-pubkey','-noout'])
b=run(['openssl','pkey','-in',str(folder/'developer-id-application.key.pem'),'-pubout'])
assert a==b, 'Returned certificate does not match retained key'
if not kc.exists():run(['security','create-keychain','-p',pw,str(kc)])
kc.chmod(0o600)
run(['security','unlock-keychain','-p',pw,str(kc)])
run(['security','set-keychain-settings','-lut','21600',str(kc)])
identity=run(['security','find-identity','-v','-p','codesigning',str(kc)])
if b'Developer ID Application: Codemyriad OU (4LS8W738Y3)' not in identity:
 for path,kind in [(folder/'developerID_application.cer','cert'),(folder/'developer-id-application.key.pem','priv')]:
  cmd=['security','import',str(path),'-k',str(kc),'-t',kind]
  if kind=='priv':cmd+=['-x','-T','/usr/bin/codesign','-T','/usr/bin/productbuild']
  existing = subprocess.run(['security','find-certificate','-c','Developer ID Application: Codemyriad OU (4LS8W738Y3)',str(kc)],capture_output=True,timeout=30) if kind=='cert' else None
  if existing is None or existing.returncode:run(cmd)
# These partitions let the two explicitly trusted Apple signing tools use the key
# non-interactively. No unrestricted -A ACL or login-keychain change.
run(['security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',pw,str(kc)])
listed=run(['security','list-keychains','-d','user']).decode();paths=re.findall(r'"([^\"]+)"',listed)
if str(kc) not in paths:run(['security','list-keychains','-d','user','-s',*paths,str(kc)])
identities=run(['security','find-identity','-v','-p','codesigning']).decode()
match=re.search(r'([0-9A-F]{40}) "Developer ID Application: Codemyriad OU \(4LS8W738Y3\)"',identities)
assert match,'Developer ID unavailable after import'
with tempfile.TemporaryDirectory(prefix='cassini-signing-probe-') as t:
 p=Path(t);src=p/'probe.c';src.write_text('int main(void){return 0;}\n');binary=p/'probe'
 run(['xcrun','clang',str(src),'-o',str(binary)])
 run(['codesign','--force','--sign',match.group(1),'--keychain',str(kc),'--options','runtime','--timestamp=none','-i','io.codemyriad.cassini.signing-probe',str(binary)])
 run(['codesign','--verify','--strict',str(binary)])
 details=subprocess.run(['codesign','-d','--verbose=4',str(binary)],capture_output=True,timeout=20).stderr
 assert b'TeamIdentifier=4LS8W738Y3' in details and b'runtime' in details
 print(json.dumps({'dedicated_keychain':True,'password_mode':'0600','keychain_mode':'0600','developer_id_visible':True,'probe_signed_and_verified':True,'probe_executed':False,'login_modified':False}))
