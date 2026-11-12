#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Local drmeyers scheduler; a hosted workflow requests work, never signs it."""
from datetime import datetime,timedelta,timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unicodedata
from zoneinfo import ZoneInfo
from user_release_notes import ReleaseNotes, parse_fragment, render

REPO='codemyriad/cassini-mac'
ORIGIN='https://github.com/'+REPO
HOME=Path.home()
BASE=HOME/'.local/share/cassini-mac-test-releases'
SOURCE=BASE/'source'
INBOX=HOME/'dev/cassini-coordination/NOTIFICATIONS-MAC-TEST-RELEASES.log'
BERLIN=ZoneInfo('Europe/Berlin')
REQUEST='request-mac-test-release.yml'


def command(args,**kwargs):
    result=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=kwargs.pop('timeout',90),**kwargs)
    if result.returncode:
        raise RuntimeError('Command failed: '+str(args[0]))
    return result.stdout


def gh(args):
    return json.loads(command(['gh','api',*args]))


def atomic(path,value):
    temporary=path.with_suffix('.tmp')
    with temporary.open('w') as stream:
        os.chmod(temporary,0o600)
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    temporary.replace(path)


def due_slot(now):
    local=now.astimezone(BERLIN)
    candidates=[local.replace(hour=hour,minute=0,second=0,microsecond=0)-timedelta(days=day)
                for day in (0,1) for hour in (9,14,20)]
    return max(slot for slot in candidates if slot<=local).isoformat()


def eligible_ci(runs,sha):
    # API pages are newest-first. PR merge-ref results (even this repo's main)
    # and fork runs must neither authorize nor block a main release.
    run=next((r for r in runs if r.get('event') in ('push','workflow_dispatch')
              and (r.get('head_repository') or {}).get('full_name')==REPO),None)
    return bool(run and run['head_sha']==sha and run['head_branch']=='main'
                and run['status']=='completed' and run['conclusion']=='success')


def main_is_green(sha):
    pages=gh(['--paginate','--slurp',f'repos/{REPO}/actions/workflows/ci.yml/runs?branch=main&head_sha={sha}&per_page=100'])
    return eligible_ci([run for page in pages for run in page['workflow_runs']],sha)


def fetch_main():
    # Include stable hotfix tags whose commits are not reachable from main.
    command(['git','-C',SOURCE,'fetch','--tags','origin','main'],timeout=180)
    return command(['git','-C',SOURCE,'rev-parse','FETCH_HEAD']).strip()


def nightly_version(source,releases):
    def parts(version):return tuple(map(int,(version+'.0').split('.')[:3]))
    stable=[parts(r['tag_name'][1:]) for r in releases if not r['draft'] and not r['prerelease']
            and re.fullmatch(r'v[0-9]+(?:\.[0-9]+){1,2}',r['tag_name'])]
    if stable and max(stable)>=parts(source):
        major,minor,patch=max(stable)
        return f'{major}.{minor}.{patch+1}'
    return source


def next_build(version,project_build,releases,state):
    pattern=re.compile(r'^v'+re.escape(version)+r'-beta\.([1-9][0-9]*)$')
    numbers=[int(m.group(1)) for r in releases if (m:=pattern.fullmatch(r['tag_name']))]
    return max([project_build,int(state.get('build',0)),*numbers])+1


def latest_nightly(releases):
    candidates=[r for r in releases if r['prerelease'] and not r['draft']
                and re.fullmatch(r'v[0-9]+(?:\.[0-9]+){1,2}-beta\.[1-9][0-9]*',r['tag_name'])
                and (r.get('name') or '').startswith('nightly')]
    return max(candidates,key=lambda r:r['published_at'],default=None)


def source_commit(release):
    value=release['target_commitish']
    if not re.fullmatch(r'[0-9a-f]{40}',value):
        raise ValueError('Prior nightly does not identify an immutable source commit')
    return value


def report(text):
    print(text,flush=True)
    INBOX.parent.mkdir(parents=True,exist_ok=True)
    with INBOX.open('a') as stream:stream.write(text+'\n')


def release_title(value):
    # A single literal code span cannot create HTML, links, images or mentions.
    text=''.join(c for c in ' '.join(value.split()) if not unicodedata.category(c).startswith('C'))
    fence='`'*(1+max((len(m.group()) for m in re.finditer(r'`+',text)),default=0))
    return fence+' '+(text or 'Untitled pull request')+' '+fence


def developer_notes(base,head):
    commits=command(['git','-C',SOURCE,'log','--reverse','--first-parent','--format=%H',
                     (base+'..'+head) if base else head]).splitlines()
    entries=[];seen=set()
    for sha in commits:
        matched=False
        for pr in gh([f'repos/{REPO}/commits/{sha}/pulls']):
            if pr.get('merged_at') and pr['base']['ref']=='main' and pr['merge_commit_sha']==sha:
                matched=True
                if pr['number'] in seen:continue
                seen.add(pr['number'])
                title=release_title(pr['title'])
                entries.append(f'- {title} ([#{pr["number"]}](https://github.com/{REPO}/pull/{pr["number"]}))')
        if not matched:
            subject=command(['git','-C',SOURCE,'show','-s','--format=%s',sha]).strip() or 'Commit '+sha[:8]
            entries.append(f'- {release_title(subject)} ([{sha[:8]}](https://github.com/{REPO}/commit/{sha}))')
    return '\n'.join([f'Source: `{head}`','',*(entries or ['No merged PR titles in this main update.'])])+'\n'


def fragment_blobs(ref):
    result={}
    for entry in command(['git','-C',SOURCE,'ls-tree','-rz',ref,'--','release-notes.d']).split('\0'):
        if not entry:continue
        metadata,path=entry.split('\t',1)
        if path=='release-notes.d/README.md':continue
        mode,kind,blob=metadata.split()
        if mode!='100644' or kind!='blob' or path.count('/')!=1:
            raise ValueError('Release fragments must be ordinary files in release-notes.d')
        result[path]=blob
    return result


def notes(base,head,include_developer=True,published_refs=()):
    published={}
    for ref in ([base] if base else [])+list(published_refs):
        for path,blob in fragment_blobs(ref).items():published.setdefault(path,set()).add(blob)
    fragments=[parse_fragment(Path(path).name,command(['git','-C',SOURCE,'show',head+':'+path]))
               for path,blob in fragment_blobs(head).items() if blob not in published.get(path,set())]
    return ReleaseNotes(render(fragments),developer_notes(base,head) if include_developer else '')


def stable_notes_source(releases):
    stable=[r for r in releases if not r['draft'] and not r['prerelease']
            and re.fullmatch(r'v[0-9]+(?:\.[0-9]+){1,2}',r['tag_name'])]
    if not stable:return None
    tag=max(stable,key=lambda r:r['published_at'])['tag_name']
    sha=command(['git','-C',SOURCE,'rev-parse','refs/tags/'+tag+'^{commit}']).strip()
    return sha


def stable_notes_base(releases,head):
    sha=stable_notes_source(releases)
    # A separately published hotfix must not wedge main's release notes.
    return command(['git','-C',SOURCE,'merge-base',sha,head]).strip() if sha else None


def publish(tag,version,build,sha,output,release_notes):
    if tag!=f'v{version}-beta.{build}':raise ValueError('Only immutable test tags may be published')
    release=json.loads((output/'test-release.json').read_text())
    if (release['channel']!='nightly' or release['commit']!=sha or release['version']!=version or release['build']!=build
            or not release['notarized'] or release['updatesEnabled'] is not False):
        raise ValueError('Test release report does not match admitted source')
    dmg=output/release['dmg']
    if dmg.name!=f'Cassini-talk-{version}-test.{build}.dmg' or dmg.parent!=output or not dmg.is_file() or dmg.is_symlink():raise ValueError('Invalid test DMG path')
    import hashlib
    digest=hashlib.sha256()
    with dmg.open('rb') as stream:
        while chunk:=stream.read(1024*1024):digest.update(chunk)
    if digest.hexdigest()!=release['sha256'] or dmg.stat().st_size!=release['bytes'] or (output/'SHA256SUMS').read_text()!=release['sha256']+'  '+dmg.name+'\n':
        raise ValueError('Test DMG differs from its notarized report')
    user_text=output/'user-release-notes.txt';user_text.write_text(release_notes.user)
    user_html=output/'user-release-notes.html';user_html.write_text(release_notes.html())
    note=output/'nightly-notes.md';note.write_text(release_notes.github())
    # A failed upload leaves a draft. Never edit, delete or overwrite another tag.
    command(['gh','release','create',tag,'-R',REPO,'--target',sha,'--title',f'nightly — {version} beta.{build}',
             '--notes-file',note,'--draft','--prerelease','--latest=false'])
    command(['gh','release','upload',tag,'-R',REPO,dmg,output/'test-release.json',output/'SHA256SUMS',user_text,user_html],timeout=1200)
    remote=gh([f'repos/{REPO}/releases/tags/{tag}'])
    expected={p.name:p.stat().st_size for p in [dmg,output/'test-release.json',output/'SHA256SUMS',user_text,user_html]}
    if not remote['draft'] or not remote['prerelease'] or {a['name']:a['size'] for a in remote['assets']}!=expected:
        raise ValueError('Draft test assets are incomplete')
    command(['gh','release','edit',tag,'-R',REPO,'--draft=false','--prerelease','--latest=false'])


def signed_build(args,env,log):
    process=subprocess.Popen(args,cwd=SOURCE,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        return process.wait(timeout=10800)
    except subprocess.TimeoutExpired:
        # Stop only this invocation's process group, including its heavy-lock
        # wrapper. Never leave a compiler holding the shared lock after timeout.
        os.killpg(process.pid,signal.SIGTERM)
        try:process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.wait()
        raise RuntimeError('Test build timed out; own process group stopped') from None


def tick(now):
    if sys.platform!='darwin' or socket.gethostname().split('.')[0].lower()!='drmeyers':
        raise ValueError('Test signing runs only on drmeyers')
    if Path(__file__).resolve().parent.parent!=SOURCE.resolve() or SOURCE.is_symlink():
        raise ValueError('Use the dedicated installed main checkout')
    if os.environ.get('CASSINI_HEAVY_LOCK_HELD')=='1':
        raise ValueError('Do not hold the heavy lock around notarization/network waits')
    state_file=BASE/'state.json'
    state=json.loads(state_file.read_text()) if state_file.exists() else {}
    slot=due_slot(now)
    stage='request check'
    try:
        request=gh([f'repos/{REPO}/actions/workflows/{REQUEST}/runs?branch=main&event=workflow_dispatch&status=completed&per_page=1'])['workflow_runs']
        manual=next((r['id'] for r in request if r['conclusion']=='success' and r['head_branch']=='main'
                     and r['event']=='workflow_dispatch' and r['id']>state.get('request',0)),None)
        if state.get('slot')==slot and manual is None:return
        state.update(slot=slot,request=manual or state.get('request',0),phase='admission')
        atomic(state_file,state)
        stage='main source/CI admission'
        if command(['git','-C',SOURCE,'remote','get-url','origin']).strip()!=ORIGIN:
            raise ValueError('Unexpected release source origin')
        def pipeline_source():
            return tuple(path.read_bytes() for path in [Path(__file__),Path(__file__).with_name('user_release_notes.py')])
        before=pipeline_source()
        head=fetch_main()
        command(['git','-C',SOURCE,'checkout','--detach','--force',head])
        # Never continue executing an older pipeline after fetching its update.
        if pipeline_source()!=before:
            state.pop('slot',None);state['request']=0;atomic(state_file,state)
            os.execv(sys.executable,[sys.executable,str(Path(__file__).resolve())])
        if not main_is_green(head):
            report('[Mac] daily test release skipped: latest main CI is not green');return
        releases=[r for page in gh(['--paginate','--slurp',f'repos/{REPO}/releases?per_page=100']) for r in page]
        previous=latest_nightly(releases)
        stable=stable_notes_source(releases)
        base=source_commit(previous) if previous else stable_notes_base(releases,head)
        if base==head or stable==head or state.get('last_success')==head:
            report('[Mac] daily test release skipped: main unchanged');return
        if base:command(['git','-C',SOURCE,'merge-base','--is-ancestor',base,head])
        if state.get('last_success') and state['last_success']!=head:
            local=state['last_success']
            if not re.fullmatch(r'[0-9a-f]{40}',local):raise ValueError('Invalid successful source commit')
            command(['git','-C',SOURCE,'merge-base','--is-ancestor',local,head])
            if base:command(['git','-C',SOURCE,'merge-base','--is-ancestor',base,local])
            base=local
        project=(SOURCE/'project.yml').read_text()
        version=re.search(r'MARKETING_VERSION: "([0-9]+(?:\.[0-9]+){1,2})"',project).group(1)
        version=nightly_version(version,releases)
        initial=int(re.search(r'CURRENT_PROJECT_VERSION: "([0-9]+)"',project).group(1))
        stage='disk reserve'
        if shutil.disk_usage(BASE).free < 25*1024**3:
            raise ValueError('At least25GiB free required before a signed test build')
        build=next_build(version,initial,releases,state)
        state.update(build=build,head=head,phase='building');atomic(state_file,state)
        stage='release notes'
        body=notes(base,head,published_refs=[stable] if stable else [])
        stage='signing/notarization'
        # The dedicated job directory is retained on failure and removed only
        # after successful publication; other agents' caches are never touched.
        job=Path(tempfile.mkdtemp(prefix=f'build-{build}-',dir=BASE));output=job/'release';derived=job/'DerivedData'
        env=dict(os.environ)
        state['job']=str(job);atomic(state_file,state)
        with (job/'release-driver.log').open('w') as log:
            code=signed_build([sys.executable,str(SOURCE/'scripts/release.py'),'--test-release','--version',version,
                '--build',str(build),'--derived-data',str(derived),'--output',str(output)],env,log)
        if code:raise RuntimeError('Signed test build failed; retained private job diagnostics')
        stage='GitHub nightly publication'
        publish(f'v{version}-beta.{build}',version,build,head,output,body)
        stage='published output cleanup'
        state.update(phase='released',last_success=head,tag=f'v{version}-beta.{build}')
        atomic(state_file,state)
        history=BASE/'history';history.mkdir(exist_ok=True)
        shutil.copy2(output/'test-release.json',history/(state['tag']+'.json'))
        report(f'[Mac] nightly {version} beta.{build} published from main {head[:8]}')
        shutil.rmtree(job) # Only this invocation's successful job output.
    except Exception as error:
        identity=stage+':'+type(error).__name__+':'+slot+':'+str(state.get('request',0))
        state.update(phase='failed')
        if state.get('failure')!=identity:
            cause=str(error).replace('\n',' ')[:180] if isinstance(error,(ValueError,RuntimeError)) else type(error).__name__
            report('[Mac] daily test release failed: '+stage+': '+cause)
        state['failure']=identity;atomic(state_file,state)
        raise SystemExit(1)


if __name__=='__main__':
    if BASE.resolve()!=BASE:
        raise SystemExit('Dedicated release storage must not follow symlinks')
    BASE.mkdir(parents=True,exist_ok=True);os.chmod(BASE,0o700)
    with (BASE/'scheduler.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise SystemExit(0)
        tick(datetime.now(timezone.utc))
