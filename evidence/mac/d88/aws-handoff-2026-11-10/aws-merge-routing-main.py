from pathlib import Path
import ast,datetime,json,re,subprocess
home=Path.home();watch=home/'coordination/AWS-MAC-CI-WATCH.py';source=watch.read_text();old=ast.literal_eval(next(x[4:] for x in source.splitlines() if x.startswith('prs=')))
rows={210:Path('/Users/ec2-user/agents/cassini-mac'),211:Path('/tmp/cassini-aws-d88-browser'),212:Path('/tmp/cassini-aws-d88-playback'),213:Path('/tmp/cassini-aws-d88-setup'),214:Path('/tmp/cassini-aws-d88-model'),215:Path('/tmp/cassini-aws-d88-transport')}
main='b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f';new={}
for n,path in rows.items():
 def git(*args):return subprocess.check_output(['git','-C',str(path),*args],text=True).strip()
 p=json.loads(subprocess.check_output(['gh','pr','view',str(n),'--repo','codemyriad/cassini-mac','--json','isDraft,headRefOid,headRefName'],text=True));assert p['isDraft'] and p['headRefOid']==old[n]==git('rev-parse','HEAD');assert not git('status','--porcelain');assert git('branch','--show-current')==p['headRefName']
 subprocess.check_call(['git','-C',str(path),'merge','--no-edit',main])
 git('diff','--check');head=git('rev-parse','HEAD');assert git('rev-parse','HEAD^2')==main
 subprocess.check_call(['git','-C',str(path),'push','origin',p['headRefName']])
 new[n]=head
 status=home/'STATUS-AWS-MAC.md';s=status.read_text().replace(f'head `{old[n][:7]}`',f'head `{head[:7]}`');s+=f'\n- Routing merge #{n}: merged main `{main}` with merge commit `{head}` and pushed {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}; exact-head CI pending.\n';status.write_text(s)
 print(n,'PUSHED',head,flush=True)
(home/'AWS-MAC-ROUTING-HEADS.json').write_text(json.dumps(new,indent=2)+'\n')
