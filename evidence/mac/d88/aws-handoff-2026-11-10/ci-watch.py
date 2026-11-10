import datetime,json,pathlib,re,subprocess,time,sys,os
repo_path=os.environ.get("CASSINI_MAC_REPO",str(pathlib.Path.home()/"agents/cassini-mac"))
prs={210: '9d373ff997c1d8721cae24fa6c805fd0da42662a', 211: '9f892f66edf6cfb5d9698b410e232dff1b15cecf', 212: '75ea82166b79dcdfc7ad084d5eb30dc71a274a11', 213: 'c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34', 214: '922711bcbde0531c834f18bccf8a2f2407462923', 215: '2a80631e207765524044523fe0b6a643d7571942'}
fields='number headRefOid isDraft commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{... on CheckRun{name status conclusion detailsUrl} ... on StatusContext{context state targetUrl}}}}}}}'
def gh_json(*args):
    return json.loads(subprocess.check_output(['gh',*args],text=True))
def mark_when_audited(summary, expected):
    number=summary['pr']
    audit=[]
    for run_id in summary['runs']:
        run=gh_json('api',f'repos/codemyriad/cassini-mac/actions/runs/{run_id}')
        if not (run['head_sha']==expected and run['status']=='completed' and run['conclusion']=='success' and run['run_attempt']==1):
            raise RuntimeError(f'#{number}: run {run_id} not exact-head first-attempt success')
        pages=gh_json('api',f'repos/codemyriad/cassini-mac/actions/runs/{run_id}/jobs?per_page=100','--paginate','--slurp')
        jobs=[job for page in pages for job in page['jobs']]
        if not jobs or any(j['status']!='completed' or j['conclusion'] not in ('success','skipped') for j in jobs):
            raise RuntimeError(f'#{number}: incomplete or nongreen job audit')
        audit.append(dict(id=run_id,url=run['html_url'],jobs=[dict(name=j['name'],conclusion=j['conclusion']) for j in jobs]))
    if not audit:raise RuntimeError(f'#{number}: missing completed workflow audit')
    pull=gh_json('api',f'repos/codemyriad/cassini-mac/pulls/{number}')
    if pull['head']['sha']!=expected or pull['base']['ref']!='main' or pull['state']!='open' or not pull['draft']:
        raise RuntimeError(f'#{number}: PR changed before readiness')
    if pull['head']['repo']['full_name']!='codemyriad/cassini-mac' or not pull['head']['ref'].startswith('test/d88-aws-'):
        raise RuntimeError(f'#{number}: unexpected branch identity')
    line=f"- 19 checked: local checks passed and all CI jobs completed green on exact head `{expected}`; [completed CI]({audit[0]['url']})."
    body,count=re.subn(r'(?m)^- 19[^\n]*$',line,pull['body'])
    if count!=1:raise RuntimeError(f'#{number}: expected exactly one D87 class 19 checklist entry')
    body_file=pathlib.Path('/tmp')/f'aws-ready-pr-{number}.md';body_file.write_text(body)
    if body!=pull['body']:
        subprocess.check_call(['gh','pr','edit',str(number),'--repo','codemyriad/cassini-mac','--body-file',str(body_file)],stdout=subprocess.DEVNULL)
    # Check again after the checklist update. This watcher never pushes branches.
    latest=gh_json('api',f'repos/codemyriad/cassini-mac/pulls/{number}')
    if latest['head']['sha']!=expected or latest['state']!='open':
        raise RuntimeError(f'#{number}: head changed immediately before marking ready')
    for entry in audit:
        fresh=gh_json('api',f"repos/codemyriad/cassini-mac/actions/runs/{entry['id']}")
        if not (fresh['head_sha']==expected and fresh['status']=='completed' and fresh['conclusion']=='success' and fresh['run_attempt']==1):
            raise RuntimeError(f'#{number}: workflow changed immediately before readiness')
    subprocess.check_call(['gh','pr','ready',str(number),'--repo','codemyriad/cassini-mac'])
    final=gh_json('api',f'repos/codemyriad/cassini-mac/pulls/{number}')
    if final['draft'] or final['head']['sha']!=expected:raise RuntimeError(f'#{number}: readiness verification failed')
    summary['draft']=False;summary['audit']=audit
    record=pathlib.Path.home()/f'READY-AWS-MAC-{number}.json'
    record.write_text(json.dumps(dict(pr=number,head=expected,audit=audit),indent=2)+'\n')
    status=pathlib.Path.home()/'STATUS-AWS-MAC.md';text=status.read_text()
    text=text.replace(f'draft PR https://github.com/codemyriad/cassini-mac/pull/{number}',f'Ready PR https://github.com/codemyriad/cassini-mac/pull/{number}')
    lines=[]
    for existing in text.splitlines():
        if f'/pull/{number},' in existing:
            existing=re.sub(r'Await exact-head CI; not ready\..*$', 'Exact-head CI green; marked ready after completed-run audit.',existing)
        lines.append(existing)
    text='\n'.join(lines)+'\n'
    text=re.sub(r'(?m)^Updated:.*$', 'Updated: '+datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC'),text)
    status.write_text(text)
    print(f'MARKED READY #{number} {expected}',flush=True)
query='query {repository(owner:"codemyriad",name:"cassini-mac"){'+' '.join('p'+str(n)+':pullRequest(number:'+str(n)+'){'+fields+'}' for n in prs)+'}}'
while True:
    summaries=[]
    try:
        payload=json.loads(subprocess.check_output(['gh','api','graphql','-f','query='+query],text=True))['data']['repository']
        summaries=[]
        for n,expected in prs.items():
            pr=payload['p'+str(n)]; c=pr['commits']['nodes'][-1]['commit']; rollup=c['statusCheckRollup']; contexts=rollup['contexts']['nodes'] if rollup else []
            pending=[x.get('name',x.get('context')) for x in contexts if x.get('status') not in ('COMPLETED',None) or x.get('state')=='PENDING']
            failed=[x.get('name',x.get('context')) for x in contexts if (x.get('status')=='COMPLETED' and x.get('conclusion') not in ('SUCCESS','SKIPPED')) or x.get('state') in ('ERROR','FAILURE')]
            matches=(expected==pr['headRefOid']==c['oid']); names={x.get('name'):x.get('conclusion') for x in contexts}
            candidate=matches and bool(contexts) and not pending and not failed and not rollup['contexts']['pageInfo']['hasNextPage'] and names.get('changes')=='SUCCESS' and names.get('CassiniKit tests and conformance')=='SUCCESS'
            if n==214: candidate=candidate and names.get('Package tests (macos-15-intel)')=='SUCCESS'
            if n==215: candidate=candidate and any(k and k.startswith('Whistle bundle') and v=='SUCCESS' for k,v in names.items())
            runs=sorted({int(m.group(1)) for x in contexts if (m:=re.search(r'/actions/runs/(\d+)',x.get('detailsUrl','')))})
            summaries.append(dict(pr=n,head=pr['headRefOid'],headMatches=matches,draft=pr['isDraft'],readyCandidate=candidate,pending=pending,failed=failed,runs=runs))
        if '--mark-ready' in sys.argv:
            for summary in summaries:
                if summary['draft'] and summary['readyCandidate']:
                    try:mark_when_audited(summary,prs[summary['pr']])
                    except Exception as error:
                        summary['auditError']=str(error); print('READINESS AUDIT: '+str(error),flush=True)
        stamp=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
        output=dict(updated=stamp,prs=summaries)
        (pathlib.Path.home()/'CI-AWS-MAC.json').write_text(json.dumps(output,indent=2)+'\n')
        status=pathlib.Path.home()/'STATUS-AWS-MAC.md'
        text=status.read_text().split('\n## CI readiness\n')[0]
        text+='\n## CI readiness\n\nLast checked: '+stamp+'\n\n'
        for s in summaries:
            text+='- #'+str(s['pr'])+' `'+s['head'][:7]+'`: '+('ready' if not s['draft'] else 'audit error: '+s['auditError'] if s.get('auditError') else 'HEAD MISMATCH' if not s['headMatches'] else 'failed: '+', '.join(s['failed']) if s['failed'] else 'green candidate, final run audit pending' if s['readyCandidate'] else 'pending: '+', '.join(s['pending']))+'; '+('draft' if s['draft'] else 'ready')+'.\n'
        status.write_text(text)
        print(json.dumps(output),flush=True)
    except Exception as error:
        print('CI audit error: '+str(error),flush=True)
    if '--watch' not in sys.argv or (summaries and all(not item['draft'] for item in summaries)):break
    time.sleep(300)
