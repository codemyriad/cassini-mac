#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline D16 worker, trust-boundary and owner-lifetime checks over private files."""
import argparse,ctypes,hashlib,json,os,select,shutil,signal,subprocess,sys,tempfile,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
SAFE=dict(NEEDLE_TELEMETRY='0',DO_NOT_TRACK='1',ORT_DISABLE_TELEMETRY='1',PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',LC_ALL='C')
p=argparse.ArgumentParser(description=__doc__)
for name in ['worker','runtime','model','vad','report']:p.add_argument('--'+name,required=True,type=Path)
a=p.parse_args()
command=[str(a.worker.resolve()),'--runtime',str(a.runtime.resolve()),'--model',str(a.model.resolve()),'--vad',str(a.vad.resolve())]
with tempfile.TemporaryDirectory(prefix='cassini-parakeet-proof-') as temp:
    temp=Path(temp);marker=temp/'constructor-loaded';source=temp/'constructor.c';library=temp/'libsherpa-onnx-c-api.dylib'
    source.write_text('#include <stdio.h>\n#include <stdlib.h>\n__attribute__((constructor)) static void loaded(void){const char*p=getenv("CASSINI_TELEMETRY_SENTINEL");if(p){FILE*f=fopen(p,"w");if(f){fputs("loaded",f);fclose(f);}}}\n')
    subprocess.run(['xcrun','clang','-dynamiclib',str(source),'-o',str(library)],check=True)
    shutil.copyfile(a.runtime/'libonnxruntime.dylib',temp/'libonnxruntime.dylib')
    (temp/'unsigned-sha256.json').write_text(json.dumps({library.name:hashlib.sha256(library.read_bytes()).hexdigest()}))
    untrusted=[str(a.worker.resolve()),'--runtime',str(temp),'--model',str(a.model.resolve()),'--vad',str(a.vad.resolve())]
    for missing in [None,'NEEDLE_TELEMETRY','DO_NOT_TRACK','ORT_DISABLE_TELEMETRY']:
        environment=dict(SAFE,CASSINI_TELEMETRY_SENTINEL=str(marker))
        if missing:environment.pop(missing)
        result=subprocess.run(untrusted,input=b'',capture_output=True,env=environment,timeout=10)
        assert result.returncode==78,(result.returncode,result.stdout,result.stderr)
        assert not marker.exists(),'Unverified runtime constructor ran'
    subprocess.run([sys.executable,'-c','import ctypes,sys;ctypes.CDLL(sys.argv[1])',str(library)],env=dict(SAFE,CASSINI_TELEMETRY_SENTINEL=str(marker)),check=True)
    assert marker.read_text()=='loaded','Constructor sentinel positive control failed'
    # Real native inference goes through the production meeting writer.
    ident=str(uuid.uuid4());meeting=temp/('Received-'+ident);meeting.mkdir()
    original=ROOT/'Tests/CassiniTranscriptionTests/Fixtures/jfk-received.opus'
    audio=original.read_bytes();(meeting/'original.opus').write_bytes(audio)
    document=dict(version=1,revision=0,id=ident,title='Private Parakeet proof',titleSource='user',notes=[],speakers=[],
                  transcript=dict(status='queued',reference=None),etaMinutes=None,error=None,quoteOverride=None,
                  received=dict(originalName='original.opus',sha256=hashlib.sha256(audio).hexdigest(),importedAtMs=int(time.time()*1000)))
    (meeting/'meeting.json').write_text(json.dumps(document))
    request=json.dumps(dict(id='parakeet-proof',meeting=str(meeting)))+'\n'
    result=subprocess.run(command,input=request.encode(),capture_output=True,env=SAFE,timeout=120)
    assert result.returncode==0,(result.returncode,result.stdout,result.stderr)
    response=json.loads(result.stdout);assert response['id']=='parakeet-proof' and 'error' not in response,response
    saved=json.loads((meeting/'meeting.json').read_text());body=json.loads((meeting/'transcript.json').read_text())
    assert saved['transcript']['status']=='done' and saved['transcript']['model']=='parakeet-ultra-0.6b-int8@18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9',saved
    assert body['language']=='und' and len(body['items'])>10,body
    assert {x['speaker'] for x in body['items']}=={'track-original'}
    assert saved['speakers']==[dict(id='track-original',name=None,provenance='unnamed',colourIndex=0)],saved
    assert (meeting/'original.opus').read_bytes()==audio
    # Invalid installed data is a distinct startup result, before any meeting
    # can be changed. The app uses this code to fall back to Whistle.
    corrupt=temp/'bad-model';corrupt.mkdir()
    for model_file in ['encoder.int8.onnx','decoder.int8.onnx','joiner.int8.onnx']:
        os.link(a.model/model_file,corrupt/model_file)
    shutil.copyfile(a.model/'tokens.txt',corrupt/'tokens.txt')
    with (corrupt/'tokens.txt').open('r+b') as stream:stream.write(b'!')
    bad_command=list(command);bad_command[bad_command.index('--model')+1]=str(corrupt)
    untouched=(meeting/'meeting.json').read_bytes()
    rejected=subprocess.run(bad_command,input=request.encode(),capture_output=True,env=SAFE,timeout=15)
    assert rejected.returncode==78 and json.loads(rejected.stdout)['code']=='invalid-model',rejected
    assert (meeting/'meeting.json').read_bytes()==untouched
    # The grandparent keeps stdin open after killing only the worker's owner.
    read_fd,write_fd=os.pipe()
    shim='import json,subprocess,sys\np=subprocess.Popen(sys.argv[2:],stdin=int(sys.argv[1]),stdout=sys.stdout,stderr=subprocess.DEVNULL)\nprint(json.dumps({"child":p.pid}),flush=True)\np.wait()\n'
    owner=subprocess.Popen([sys.executable,'-u','-c',shim,str(read_fd),*command],pass_fds=(read_fd,),stdout=subprocess.PIPE,env=SAFE)
    os.close(read_fd);child=None
    try:
        assert select.select([owner.stdout],[],[],10)[0],'Owner did not announce its worker'
        child=json.loads(owner.stdout.readline())['child'];time.sleep(.6)
        live=subprocess.run(['/bin/ps','-p',str(child),'-o','stat='],capture_output=True,text=True)
        assert live.returncode==0 and not live.stdout.strip().startswith('Z'),'Worker failed while owner was alive'
        owner.kill();owner.wait(timeout=5)
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            status=subprocess.run(['/bin/ps','-p',str(child),'-o','stat='],capture_output=True,text=True)
            if status.returncode or status.stdout.strip().startswith('Z'):child=None;break
            time.sleep(.05)
        assert child is None,'Worker survived owner death with stdin held open'
    finally:
        os.close(write_fd)
        if owner.poll() is None:owner.kill();owner.wait(timeout=5)
        if child:
            try:os.kill(child,signal.SIGKILL)
            except ProcessLookupError:pass
report=dict(productionMeetingWorker=True,unverifiedConstructorRejected=True,privacyBeforeDlopen=True,sourceAudioUnchanged=True,language='und',speaker='track-original',ownerDeathStopsWorker=True,invalidModelHasDistinctCode=True,wordCount=len(body['items']),audioDevicesOpened=False)
a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,indent=2)+'\n')
print('PASS D16 real meeting worker, source trust/privacy, unchanged audio, unnamed received speaker and owner death')
