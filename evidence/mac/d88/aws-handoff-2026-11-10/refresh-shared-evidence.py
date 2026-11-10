from pathlib import Path
import subprocess,json,re,datetime,shutil
home=Path.home()
heads={int(n):sha for n,sha in re.findall(r'(21[0-5]) PUSHED ([0-9a-f]{40})',Path('/tmp/aws-apply-supersession.log').read_text())}
assert len(heads)==6
watch=home/'coordination/AWS-MAC-CI-WATCH.py'
s=watch.read_text();s=re.sub(r'^prs=.*$', 'prs='+repr(heads),s,flags=re.M)
s=s.replace(" and all(not payload['p'+str(k)]['isDraft'] and payload['p'+str(k)]['headRefOid']==prs[k] for k in range(210,215))",'')
watch.write_text(s)
for n,head in heads.items():
 p=json.loads(subprocess.check_output(['gh','pr','view',str(n),'--json','body,headRefOid,isDraft'],text=True))
 assert p['headRefOid']==head and p['isDraft']
 body=p['body'].replace('shared ModelSupersessionTests failures currently block Kit and are assigned to aws-mac for repair.','the shared ModelSupersessionTests blocker is repaired on this head as described below.')
 base=f'https://github.com/codemyriad/cassini-mac/blob/{head}/evidence/mac/d88/aws-supersession'
 section=f'''## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction]({base}/before-held-pool.log), [fixed reproduction]({base}/after-held-pool.log), [mutation patch]({base}/skip-revalidation.patch), [failing mutation]({base}/skip-revalidation.log), [restored run]({base}/restored.log), [this row plus shared suite]({base}/row-local.log), [recipe and scope]({base}/README.md).

'''
 body=body.replace('## Checked bug classes',section+'## Checked bug classes',1)
 # Existing row-specific class entries remain; shared fixture adds these checks.
 body=body.replace('- 1–14 and 16 not applicable to this test-only fixture.','- 1–14 not applicable to this test-only fixture.')
 body=body.replace('## Checked bug classes\n','## Checked bug classes\n\n- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.\n',1)
 f=Path(f'/tmp/aws-pr-{n}-shared.md');f.write_text(body)
 subprocess.check_call(['gh','pr','edit',str(n),'--body-file',str(f)],stdout=subprocess.DEVNULL)
 print(n,head,'body updated',flush=True)
status=home/'STATUS-AWS-MAC.md';text=status.read_text()
old=['f0b06cc','54c574b','ac49a75','3fd8e39','21e957a','8f5cdab']
for n,o in zip(heads,old):text=text.replace(f'head `{o}`',f'head `{heads[n][:7]}`')
text=text.replace('Readiness for #215 follows #210–#214, per coordinator priority.','All six may become ready independently when exact-head CI is green.')
text=text.replace('No Mac heavy run currently active.','All six new heads passed their affected row tests plus seven ordinary supersession tests under the shared lock; no local heavy run currently active.')
start=text.index('## Current blocker');end=text.index('## CI readiness',start)
text=text[:start]+'''## Current blocker

The shared ModelSupersessionTests:93 CI blocker is fixed on all six pushed heads. A controlled held-cooperative-worker reproduction failed both original parameter variants; the dedicated fixture executor passes both. Seven ordinary tests pass; removing replacement hash revalidation fails hash-error and old-copy-retention assertions; restored eight ordinary/probe tests pass. Each PR includes linked D87 and mutation evidence. Await exact-head full CI; no hosted reruns, merges or agy self-checks.

## Questions

None. Ownership of the shared blocker was explicitly assigned to aws-mac and the repair is complete locally. Proof/recipe is pushed on `test/d88-aws-supersession-events` and copied into each PR's evidence. #208 remains open at the last check; ARM routing awaits its merge. Continue monitoring all six independently.

'''+text[end:]
text=re.sub(r'(?m)^Updated:.*$', 'Updated: '+datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC'),text)
text=text.replace('CI Kit failed in unrelated ModelSupersessionTests:93 (two replacement-lock observer timeouts); the changed playback test passed. No rerun. Evidence/owner routing in handoff `ci-blocker-212.md`.','The shared ModelSupersessionTests:93 failure is repaired locally on all six heads; changed playback cancellation and shared fixture tests pass. Await new exact-head CI.')
status.write_text(text)
archive=Path('/tmp/cassini-aws-d88-handoff/evidence/mac/d88/aws-handoff-2026-11-10')
shutil.copyfile('/tmp/aws-apply-supersession.py',archive/'apply-supersession.py')
shutil.copyfile('/tmp/aws-refresh-shared-evidence.py',archive/'refresh-shared-evidence.py')
