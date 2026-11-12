#!/usr/bin/env python3
"""Replay only the dedicated local CI account's root-private auto-login file."""
import os,pwd,stat,subprocess
from pathlib import Path
assert os.geteuid()==0 and pwd.getpwnam('cassinigui').pw_uid==503
secret=Path('/var/root/.config/cassini-gui-login/password')
s=secret.stat();assert s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600
current=subprocess.run(['defaults','read','/Library/Preferences/com.apple.loginwindow','autoLoginUser'],capture_output=True,text=True)
assert current.returncode!=0 or current.stdout.strip()=='cassinigui','Another account owns automatic login'
password=secret.read_bytes().strip()+b'\0';password+=b'\0'*((-len(password))%12)
key=bytes([0x7d,0x89,0x52,0x23,0xd2,0xbc,0xdd,0xea,0xa3,0xb9,0x1f])
fd=os.open('/etc/kcpassword',os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'wb') as output:
 os.fchmod(output.fileno(),0o600);output.write(bytes(c^key[i%len(key)] for i,c in enumerate(password)))
for key,value,kind in [('autoLoginUser','cassinigui','-string'),('autoLoginUserUID','503','-int')]:
 subprocess.run(['defaults','write','/Library/Preferences/com.apple.loginwindow',key,kind,value],check=True)
print('Dedicated CI automatic login configured; password never printed')
