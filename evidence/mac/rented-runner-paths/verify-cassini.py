"""Run real Cassini producer/consumer commands at two paths under the shared lock."""
from pathlib import Path
import json,os,shutil,subprocess,sys,tempfile
root=Path(__file__).resolve().parents[3]
evidence=Path(__file__).resolve().parent/'cassini'
evidence.mkdir(exist_ok=True)
base='17162d0ab810ddaeb65a17d3b7abfbb8b5c295f2'
selected='compiledSourcePinsMatchPublication|readinessCanDependOnTheCallingActorMakingProgress|testLiteralWireVectorsThroughTheProductionRegistry'
def run(label,command,cwd,success=True,env=None):
    print(label,flush=True)
    result=subprocess.run(list(map(str,command)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=600)
    (evidence/(label+'.log')).write_text(result.stdout)
    if (result.returncode==0)!=success:raise RuntimeError(f'{label}: exit {result.returncode}')
    return result.stdout
with tempfile.TemporaryDirectory(prefix='cassini-real-paths-') as temporary:
    work=Path(temporary).resolve();a=work/'producer';b=work/'consumer';artifact=work/'artifact'
    for name,destination in [('producer',a),('consumer',b)]:
        run(name+'-clone',['git','clone','--shared','--quiet',root,destination],work)
        run(name+'-checkout',['git','checkout','--quiet','--detach',base],destination)
    run('producer-build',['swift','build','--build-tests','--jobs','4'],a)
    run('producer-tests',['swift','test','--skip-build','--filter',selected],a)
    cli=[sys.executable,'scripts/ci-products.py']
    run('pack',cli+['pack','swiftpm',artifact],a)
    metadata=json.loads((artifact/'swiftpm.json').read_text());assert metadata['workspace']==str(a)
    (evidence/'producer-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    # Only bounds compile concurrency: all commands delegate to the actual toolchain.
    swift=subprocess.check_output(['xcrun','--find','swift'],text=True).strip()
    tools=work/'tools';tools.mkdir()
    wrapper=tools/'swift'
    import shlex
    wrapper.write_text('#!/bin/bash\nset -e\nif [[ "$1" == build ]]; then\n  exec '+shlex.quote(swift)+' "$@" --jobs 4\nfi\nexec '+shlex.quote(swift)+' "$@"\n')
    wrapper.chmod(0o755)
    env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH'])
    hidden=work/'producer-unavailable';a.rename(hidden)
    try:
        rejected=run('foreign-unpack',cli+['unpack','swiftpm',artifact],b,success=False)
        assert 'WorkspaceMismatch' in rejected and not (b/'.build').exists()
        restored=run('consumer-restore',cli+['restore','swiftpm',artifact],b,env=env)
        assert 'building test products in this checkout' in restored
        run('consumer-tests',['swift','test','--skip-build','--filter',selected],b,env=env)
        assert not a.exists()
        accessors=list((b/'.build').rglob('resource_bundle_accessor.swift'))
        assert accessors and all(str(a) not in p.read_text() for p in accessors)
        assert any(str(b) in p.read_text() for p in accessors)
        (evidence/'consumer-resource-accessor.swift').write_text(accessors[0].read_text())
        (evidence/'result.json').write_text(json.dumps(dict(base=base,producer=str(a),consumer=str(b),producerUnavailable=True,filter=selected,result='Producer build/pack, foreign rejection, real consumer-local rebuild and 3 path-dependent tests passed'),indent=2)+'\n')
    finally:
        assert not a.exists(), "The old producer path must stay unavailable throughout consumption"
run('ci-contract', [sys.executable, root/'scripts/test-ci-contract.py'], root)
print('Actual Cassini two-path producer/consumer proof passed',flush=True)
