import contextlib,io,pathlib,tempfile,types,copy
source=pathlib.Path(__file__).with_name('ci-watch.py').read_text().split("query='query")[0]
ns={};exec(source,ns)
real_path=pathlib.Path
with tempfile.TemporaryDirectory() as directory:
    root=real_path(directory);(root/'tmp').mkdir();(root/'STATUS-AWS-MAC.md').write_text('# Offline fixture\n- draft PR https://github.com/codemyriad/cassini-mac/pull/999\n')
    class FakePath:
        def __new__(cls,value):return root/'tmp' if value=='/tmp' else real_path(value)
        @staticmethod
        def home():return root
    ns['pathlib']=types.SimpleNamespace(Path=FakePath)
    expected='a'*40
    pull=dict(head=dict(sha=expected,ref='test/d88-aws-fixture',repo=dict(full_name='codemyriad/cassini-mac')),base=dict(ref='main'),state='open',draft=True,body='## Checked bug classes\n- 19 pending CI\n')
    run=dict(head_sha=expected,status='completed',conclusion='success',run_attempt=1,html_url='https://example.invalid/offline-ci')
    jobs=[dict(jobs=[dict(name='changes',status='completed',conclusion='success')])]
    def check(case):
        calls=[];reads=0
        test_run=copy.deepcopy(run);test_pull=copy.deepcopy(pull);test_jobs=copy.deepcopy(jobs)
        if case=='wrong_head':test_run['head_sha']='b'*40
        if case=='failed_run':test_run['conclusion']='failure'
        if case=='retry_attempt':test_run['run_attempt']=2
        if case=='pending_job':test_jobs[0]['jobs'][0]['status']='queued';test_jobs[0]['jobs'][0]['conclusion']=None
        if case=='missing_checklist':test_pull['body']='No readiness checklist'
        def gh_json(*args):
            nonlocal reads
            endpoint=args[1]
            if '/jobs?' in endpoint:return copy.deepcopy(test_jobs)
            if '/actions/runs/' in endpoint:return copy.deepcopy(test_run)
            if '/pulls/' in endpoint:
                reads+=1;value=copy.deepcopy(test_pull)
                if case=='head_changed' and reads>=2:value['head']['sha']='c'*40
                if reads>=3:value['draft']=False
                return value
            raise AssertionError(endpoint)
        ns['gh_json']=gh_json
        ns['subprocess']=types.SimpleNamespace(DEVNULL=-3,check_call=lambda args,**kw:calls.append(args))
        summary=dict(pr=999,runs=[1],draft=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):ns['mark_when_audited'](summary,expected)
        except RuntimeError:
            assert case!='success'
        else:assert case=='success' and summary['draft']==False
        ready=[call for call in calls if call[:3]==['gh','pr','ready']]
        assert bool(ready)==(case=='success'),(case,calls)
        assert all(call[:3] in (['gh','pr','edit'],['gh','pr','ready']) for call in calls)
        print(case+': PASS (offline)')
    for case in ['success','wrong_head','failed_run','retry_attempt','pending_job','missing_checklist','head_changed']:check(case)
