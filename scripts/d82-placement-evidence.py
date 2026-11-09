#!/usr/bin/env python3
"""CI-only paired stream-reader proof on actual Mac consumer output."""
from pathlib import Path
import contextlib,hashlib,importlib.util,io,json,os,statistics,sys,time
from unittest.mock import patch


def load(label,path):
    spec=importlib.util.spec_from_file_location('d82_'+label,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def measure(base,output,manifest,result):
    base,output=Path(base),Path(output);output.mkdir(parents=True,exist_ok=True)
    modules={label:load(label,base/(label+'.py')) for label in ('baseline','candidate')}
    expected=None; counts={};timings={label:[] for label in modules}
    def invoke(label):
        nonlocal expected
        with contextlib.redirect_stdout(io.StringIO()) as text:
            status=modules[label].main(manifest,result)
        if status!=0:raise RuntimeError(label+' oracle failed: '+text.getvalue())
        actual=Path(result).read_bytes()
        if expected is None:expected=actual
        if expected!=actual:raise RuntimeError('Baseline and candidate results differ')
    # Count one warm-up run separately from timings, retaining all real I/O.
    original=Path.read_bytes
    for label in modules:
        count={'reads':0,'bytes':0}
        def counted(path):
            data=original(path)
            if path.suffix=='.f32':count['reads']+=1;count['bytes']+=len(data)
            return data
        with patch.object(Path,'read_bytes',counted):invoke(label)
        counts[label]=count
    # Reverse each successive pair to counterbalance warm cache/order effects.
    for trial in range(5):
        for label in (('baseline','candidate') if trial%2==0 else ('candidate','baseline')):
            start=time.perf_counter();invoke(label);timings[label].append(time.perf_counter()-start)
    if counts['candidate']['reads']>=counts['baseline']['reads']:raise RuntimeError('Expected fewer stream reads')
    if counts['candidate']['bytes']>=counts['baseline']['bytes']:raise RuntimeError('Expected fewer bytes read')
    value=dict(mutant=json.loads(Path(manifest).read_text())['mutant'],counts=counts,timingsSeconds=timings,
               mediansSeconds={label:statistics.median(values) for label,values in timings.items()},
               resultSHA256=hashlib.sha256(expected).hexdigest(),
               sourceSHA256={label:hashlib.sha256((base/(label+'.py')).read_bytes()).hexdigest() for label in modules},
               architecture=os.uname().machine,sdkCommit='023c443f07779b660c1cbde157c598b6da143271')
    (output/((value['mutant'] or 'clean')+'.json')).write_text(json.dumps(value,indent=2)+'\n')
    print(json.dumps(value),flush=True)


def install(base,output):
    base=Path(base);target=Path('scripts/placement-measure.py')
    (base/'baseline.py').write_bytes(target.read_bytes())
    helper=Path(__file__).resolve()
    target.write_text('import sys,runpy\nsys.argv = '+repr([str(helper),'measure',str(base),output])+' + sys.argv[1:]\nrunpy.run_path('+repr(str(helper))+',run_name="__main__")\n')


if __name__=='__main__':
    if sys.argv[1]=='install':install(*sys.argv[2:])
    elif sys.argv[1]=='measure':measure(*sys.argv[2:])
    else:raise SystemExit('Expected install or measure')
