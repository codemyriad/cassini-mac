from pathlib import Path
import json,subprocess,re
home=Path.home();heads=json.loads((home/'AWS-MAC-ROUTING-HEADS.json').read_text());archive='f3baf1172ebfcb93ecc66322cb4ee2c013718e66';main='b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f'
for n,head in heads.items():
 p=json.loads(subprocess.check_output(['gh','pr','view',n,'--repo','codemyriad/cassini-mac','--json','body,headRefOid,isDraft'],text=True));assert p['headRefOid']==head and p['isDraft']
 url=f'https://github.com/codemyriad/cassini-mac/blob/{archive}/evidence/mac/d88/aws-handoff-2026-11-10/routing-merge-validation/{n}.log'
 section=f'''## Rented-Mac routing merge validation

Merged main `{main}` with an ordinary merge commit, without rebasing. Current exact head: `{head}`. Affected row tests plus all seven shared supersession tests pass under the shared heavy-run lock, Xcode 16.4 / four jobs. [Merged-head local log]({url}); the log is archived on the handoff branch so preserving evidence does not change the tested PR head. Prior mutation links remain valid evidence for the unchanged row implementation. Full CI on this new head is pending; ARM build jobs now request `cm-mac-m4`.

'''
 b=p['body'];assert '## Rented-Mac routing merge validation' not in b
 b=b.replace('## Checked bug classes',section+'## Checked bug classes',1)
 b,count=re.subn(r'(?m)^- 19[^\n]*$',f'- 19 pending: keep draft until full CI is green on exact merged head `{head}`; merged-head local checks passed.',b);assert count==1
 f=Path(f'/tmp/aws-routing-pr-{n}.md');f.write_text(b)
 subprocess.check_call(['gh','pr','edit',n,'--repo','codemyriad/cassini-mac','--body-file',str(f)],stdout=subprocess.DEVNULL)
 print(n,head,'body refreshed',flush=True)
