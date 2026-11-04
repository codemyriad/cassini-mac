#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Import a returned certificate into an isolated local signing keychain; no app runs.

Several `security` commands take the keychain password on argv, so every command
goes through safe_process (shared with release.py): a failing, hanging, unlaunchable
or interrupted command reports only the tool and its subcommand, with no argv, no
output, no exception chain and no traceback.
"""
from pathlib import Path
import subprocess,secrets,os,json,re,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import safe_process  # noqa: E402
FOLDER=Path.home()/'.config/cassini/secrets'
IDENTITY='Developer ID Application: Codemyriad OU (4LS8W738Y3)'

class SetupError(safe_process.CommandError):
 """A message that is safe to print: it never contains argv or tool output."""

def run(command,runner=None,timeout=30):
 return safe_process.run(command,runner=runner,timeout=timeout).stdout

def call(command,runner=None,timeout=30):
 return safe_process.run(command,runner=runner,timeout=timeout,check=False)

def check(condition,message):
 if not condition:raise SetupError(message)

def main(folder=FOLDER,runner=None):
 kc=folder/'cassini-signing.keychain-db';pwfile=folder/'cassini-signing-keychain.password'
 run_=lambda command,timeout=30:run(command,runner,timeout)
 if not pwfile.exists():
  fd=os.open(pwfile,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as f:f.write(secrets.token_urlsafe(48))
 pw=pwfile.read_text();pwfile.chmod(0o600)
 a=run_(['openssl','x509','-inform','DER','-in',str(folder/'developerID_application.cer'),'-pubkey','-noout'])
 b=run_(['openssl','pkey','-in',str(folder/'developer-id-application.key.pem'),'-pubout'])
 check(a==b,'Returned certificate does not match retained key')
 if not kc.exists():run_(['security','create-keychain','-p',pw,str(kc)])
 kc.chmod(0o600)
 run_(['security','unlock-keychain','-p',pw,str(kc)])
 run_(['security','set-keychain-settings','-lut','21600',str(kc)])
 identity=run_(['security','find-identity','-v','-p','codesigning',str(kc)])
 if IDENTITY.encode() not in identity:
  for path,kind in [(folder/'developerID_application.cer','cert'),(folder/'developer-id-application.key.pem','priv')]:
   cmd=['security','import',str(path),'-k',str(kc),'-t',kind]
   if kind=='priv':cmd+=['-x','-T','/usr/bin/codesign','-T','/usr/bin/productbuild']
   existing=call(['security','find-certificate','-c',IDENTITY,str(kc)],runner) if kind=='cert' else None
   if existing is None or existing.returncode:run_(cmd)
 # These partitions let the two explicitly trusted Apple signing tools use the key
 # non-interactively. No unrestricted -A ACL or login-keychain change.
 run_(['security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',pw,str(kc)])
 listed=run_(['security','list-keychains','-d','user']).decode();paths=re.findall(r'"([^\"]+)"',listed)
 if str(kc) not in paths:run_(['security','list-keychains','-d','user','-s',*paths,str(kc)])
 identities=run_(['security','find-identity','-v','-p','codesigning']).decode()
 match=re.search(r'([0-9A-F]{40}) "Developer ID Application: Codemyriad OU \(4LS8W738Y3\)"',identities)
 check(match,'Developer ID unavailable after import')
 with tempfile.TemporaryDirectory(prefix='cassini-signing-probe-') as t:
  p=Path(t);src=p/'probe.c';src.write_text('int main(void){return 0;}\n');binary=p/'probe'
  run_(['xcrun','clang',str(src),'-o',str(binary)])
  run_(['codesign','--force','--sign',match.group(1),'--keychain',str(kc),'--options','runtime','--timestamp=none','-i','io.codemyriad.cassini.signing-probe',str(binary)])
  run_(['codesign','--verify','--strict',str(binary)])
  details=call(['codesign','-d','--verbose=4',str(binary)],runner,20).stderr
  check(b'TeamIdentifier=4LS8W738Y3' in details and b'runtime' in details,'Probe signature lacks the team or hardened runtime')
 return {'dedicated_keychain':True,'password_mode':'0600','keychain_mode':'0600','developer_id_visible':True,'probe_signed_and_verified':True,'probe_executed':False,'login_modified':False}

def cli(folder=FOLDER,runner=None):
 # Any exception, a timeout or Ctrl-C included, ends in one sanitized line and an exit status.
 safe_process.guard(lambda:print(json.dumps(main(folder,runner))),'Signing keychain setup failed')

if __name__=='__main__':cli()
