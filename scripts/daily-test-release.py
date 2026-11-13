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
CI_WAIT_BUDGET=timedelta(minutes=45)
CI_START_GRACE=timedelta(minutes=3)


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


def ci_state(runs,sha):
    # API pages are newest-first. PR/fork results and non-push runs (schedule,
    # workflow_dispatch) must neither authorize nor block a main release.
    run=next((r for r in runs if r.get('event')=='push'
              and (r.get('head_repository') or {}).get('full_name')==REPO),None)
    if not run:return 'missing'
    if run.get('head_sha')!=sha or run.get('head_branch')!='main':return 'red'
    if run.get('status')!='completed':return 'pending'
    return 'green' if run.get('conclusion')=='success' else 'red'


def eligible_ci(runs,sha):
    return ci_state(runs,sha)=='green'


def main_ci_state(sha):
    pages=gh(['--paginate','--slurp',f'repos/{REPO}/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha={sha}&per_page=100'])
    return ci_state([run for page in pages for run in page['workflow_runs']],sha)


def main_is_green(sha):
    return main_ci_state(sha)=='green'


def parse_utc(value,default=None):
    if not isinstance(value,str):return default
    try:parsed=datetime.fromisoformat(value)
    except ValueError:return default
    return parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def git_ok(*args):
    try:command(['git','-C',SOURCE,*args]);return True
    except RuntimeError:return False


def candidate_publishable(candidate,state):
    local=state.get('last_success')
    if local:
        if not isinstance(local,str) or not re.fullmatch(r'[0-9a-f]{40}',local):
            raise ValueError('Invalid successful source commit')
        if local==candidate or not git_ok('merge-base','--is-ancestor',local,candidate):
            return False
    releases=[r for page in gh(['--paginate','--slurp',f'repos/{REPO}/releases?per_page=100']) for r in page]
    previous=latest_nightly(releases)
    stable=stable_notes_source(releases)
    base=source_commit(previous) if previous else stable_notes_base(releases,candidate)
    if candidate==base or candidate==stable:
        return False
    return not base or git_ok('merge-base','--is-ancestor',base,candidate)


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
    remote=json.loads(command(['gh','release','view',tag,'-R',REPO,'--json','isDraft,isPrerelease,assets']))
    expected={p.name:p.stat().st_size for p in [dmg,output/'test-release.json',output/'SHA256SUMS',user_text,user_html]}
    assets=remote['assets']
    if (not remote['isDraft'] or not remote['isPrerelease']
            or len(assets)!=len(expected) or any(a.get('state')!='uploaded' for a in assets)
            or {a['name']:a['size'] for a in assets}!=expected):
        raise ValueError('Draft test assets are incomplete')
    command(['gh','release','edit',tag,'-R',REPO,'--draft=false','--prerelease','--latest=false'])


# With DerivedData on the external volume the internal disk holds only the job's products, logs and notary files:
# the 13 GiB (10 GiB host reserve + 3 GiB) that release.py's own checks then ask of the products' disk.
EXTERNAL_INTERNAL_RESERVE=13*1024**3


def external_build():
    """(runner, root) when the agent's environment sends DerivedData to an external volume, else None.

    CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT names a folder inside /Volumes/<volume>, and
    CASSINI_MAC_TEST_RELEASE_AQUA the program that runs a command in the logged-in session (on drmeyers,
    ~/bin/guirun). A LaunchAgent cannot open a removable volume, so this process only passes the path on; the
    helper checks the mount, the free space and symlinks where it can see them. One variable without the other,
    or a runner that is not an installed program, fails the job before a build number is used.
    """
    root=os.environ.get('CASSINI_MAC_TEST_RELEASE_DERIVED_ROOT','')
    runner=os.environ.get('CASSINI_MAC_TEST_RELEASE_AQUA','')
    if not root and not runner:return None
    if not root or not runner:
        raise ValueError('External DerivedData needs both its root and the logged-in session runner')
    parts=Path(root).parts
    if not Path(root).is_absolute() or len(parts)<4 or parts[1]!='Volumes' or '..' in parts:
        raise ValueError('External build root must be a folder inside /Volumes/<volume>')
    if not Path(runner).is_absolute() or not Path(runner).is_file() or not os.access(runner,os.X_OK):
        raise ValueError('Logged-in session runner is not an installed program')
    return runner,root


def signed_build(args,env,log):
    process=subprocess.Popen(args,cwd=SOURCE,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        # Six hours covers two 60m lock waits, two notarizations (600s
        # submit + 2800s wait + 360s staple/validate each), 600s DMG,
        # 3600s compilation and 900s setup/signing margin: 19820s.
        return process.wait(timeout=21600)
    except subprocess.TimeoutExpired:
        # Stop only this invocation's process group, including its heavy-lock
        # wrapper. Never leave a compiler holding the shared lock after timeout.
        os.killpg(process.pid,signal.SIGTERM)
        try:process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.wait()
        raise RuntimeError('Test build timed out; own process group stopped') from None


def failed_job(path):
    marker=path/'job.json'
    if path.is_symlink() or not path.is_dir() or marker.is_symlink() or not marker.is_file():return None
    try:meta=json.loads(marker.read_text())
    except (OSError,ValueError):return None
    if not isinstance(meta,dict):return None
    if (meta.get('schema')!='cassini-mac-test-job@1' or meta.get('phase')!='failed'
            or type(meta.get('build')) is not int or meta['build']<1
            or not isinstance(meta.get('head'),str) or not re.fullmatch(r'[0-9a-f]{40}',meta['head'])):return None
    return meta


def prune_failed_builds():
    """Never touch active, unmarked, symlinked jobs or shared build caches."""
    failed=[path for path in BASE.glob('build-*') if failed_job(path)]
    if not failed:return
    archive=BASE/'failures'
    if archive.is_symlink():raise ValueError('Diagnostic archive must not follow a symlink')
    archive.mkdir(exist_ok=True);os.chmod(archive,0o700)
    for job in failed:
        metadata=failed_job(job)
        if metadata is None:continue
        destination=archive/job.name
        if destination.is_symlink():raise ValueError('Diagnostic job must not follow a symlink')
        existing=failed_job(destination) if destination.exists() else None
        if destination.exists() and (existing is None or existing['build']!=metadata['build'] or existing['head']!=metadata['head']):
            raise ValueError('Refusing an unowned diagnostic directory')
        destination.mkdir(exist_ok=True);os.chmod(destination,0o700)
        atomic(destination/'job.json',metadata)
        # At most five 1MiB tails per job. Never recurse into products/DerivedData.
        for name in ['release-driver.log','release/build.log','release/app-notary.json','release/dmg-notary.json','release/test-release.json']:
            source=job/name
            if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(job.resolve()):continue
            with source.open('rb') as stream:
                stream.seek(max(0,source.stat().st_size-1024**2));tail=stream.read(1024**2)
            target=destination/(name.replace('/','-')+'.tail')
            # Atomic replacement cannot follow an existing file symlink.
            temporary=None
            try:
                with tempfile.NamedTemporaryFile(dir=destination,prefix='.tail-',delete=False) as stream:
                    temporary=Path(stream.name);stream.write(tail);stream.flush();os.fsync(stream.fileno())
                temporary.replace(target)
            finally:
                if temporary is not None and temporary.exists():temporary.unlink()
        shutil.rmtree(job)
    retained=[path for path in archive.glob('build-*') if failed_job(path)]
    for path in sorted(retained,key=lambda p:failed_job(p)['build'],reverse=True)[3:]:
        shutil.rmtree(path)


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
    job=None
    manual=None
    try:
        request=gh([f'repos/{REPO}/actions/workflows/{REQUEST}/runs?branch=main&event=workflow_dispatch&status=completed&per_page=1'])['workflow_runs']
        manual=next((r['id'] for r in request if r['conclusion']=='success' and r['head_branch']=='main'
                     and r['event']=='workflow_dispatch' and r['id']>state.get('request',0)),None)
        if state.get('slot')==slot and manual is None:return
        stage='main source/CI admission'
        now_utc=now.astimezone(timezone.utc)
        request_id=manual or state.get('request',0)
        attempt_request=manual or 0
        prior=state.get('pending_ci')
        same_attempt=isinstance(prior,dict) and prior.get('slot')==slot and prior.get('request')==attempt_request
        prior_started=parse_utc(prior.get('started_at')) if same_attempt else now_utc
        if same_attempt and (prior_started is None or now_utc-min(prior_started,now_utc)>=CI_WAIT_BUDGET):
            state.pop('pending_ci',None)
            state.update(slot=slot,request=request_id,phase='skipped')
            atomic(state_file,state)
            report('[Mac] daily test release skipped: main CI did not finish green within 45m')
            return
        started_at=min(prior_started,now_utc)
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
        head_started_at=min(parse_utc(prior.get('head_started_at'),now_utc),now_utc) if (same_attempt and prior.get('head')==head) else now_utc
        raw_candidates=prior.get('candidates') if (same_attempt and isinstance(prior.get('candidates'),list)) else []
        seen=[];seen_shas={head}
        for item in raw_candidates:
            if not isinstance(item,dict):continue
            sha=item.get('sha')
            if isinstance(sha,str) and re.fullmatch(r'[0-9a-f]{40}',sha) and sha not in seen_shas:
                seen_shas.add(sha)
                seen.append(dict(sha=sha,seen_at=min(parse_utc(item.get('seen_at'),started_at),now_utc).isoformat()))
        status=main_ci_state(head)
        kept=[]
        if status in ('pending','missing'):
            for item in seen:
                candidate=item['sha']
                candidate_since=min(parse_utc(item['seen_at'],started_at),now_utc)
                if (not git_ok('merge-base','--is-ancestor',candidate,head)
                        or not git_ok('diff','--quiet',candidate,head,'--','scripts/daily-test-release.py','scripts/user_release_notes.py')):
                    continue
                candidate_status=main_ci_state(candidate)
                if candidate_status=='green' and candidate_publishable(candidate,state):
                    command(['git','-C',SOURCE,'checkout','--detach','--force',candidate])
                    head=candidate
                    status='green'
                    break
                if candidate_status=='pending' or (candidate_status=='missing' and now_utc-candidate_since<CI_START_GRACE):
                    kept.append(item)
        if status!='green':
            if status=='red' or (status=='missing' and now_utc-head_started_at>=CI_START_GRACE):
                state.pop('pending_ci',None)
                state.update(slot=slot,request=request_id,phase='skipped')
                atomic(state_file,state)
                report('[Mac] daily test release skipped: latest main CI is not green')
                return
            if not same_attempt or prior.get('head')!=head:
                report('[Mac] daily test release waiting: latest main CI is not green')
            candidates=([dict(sha=head,seen_at=head_started_at.isoformat())]+kept)[:8]
            state['pending_ci']=dict(slot=slot,request=attempt_request,head=head,started_at=started_at.isoformat(),
                                     head_started_at=head_started_at.isoformat(),candidates=candidates)
            atomic(state_file,state)
            return
        state.pop('pending_ci',None)
        atomic(state_file,state)
        stage='failed output cleanup'
        prune_failed_builds()
        stage='release history'
        state.update(slot=slot,request=manual or state.get('request',0),phase='admission')
        atomic(state_file,state)
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
            if not base or subprocess.run(['git','-C',str(SOURCE),'merge-base','--is-ancestor',base,local],capture_output=True).returncode==0:
                base=local
            else:
                # The publish response may have been lost before local state saved.
                command(['git','-C',SOURCE,'merge-base','--is-ancestor',local,base])
        project=(SOURCE/'project.yml').read_text()
        version=re.search(r'MARKETING_VERSION: "([0-9]+(?:\.[0-9]+){1,2})"',project).group(1)
        version=nightly_version(version,releases)
        initial=int(re.search(r'CURRENT_PROJECT_VERSION: "([0-9]+)"',project).group(1))
        stage='disk reserve'
        external=external_build()
        if external is None and shutil.disk_usage(BASE).free < 25*1024**3:
            raise ValueError('At least25GiB free required before a signed test build')
        if external is not None and shutil.disk_usage(BASE).free < EXTERNAL_INTERNAL_RESERVE:
            raise ValueError('At least13GiB free required for the products of a signed test build')
        build=next_build(version,initial,releases,state)
        state.update(build=build,head=head,phase='building');atomic(state_file,state)
        stage='release notes'
        body=notes(base,head,published_refs=[stable] if stable else [])
        stage='signing/notarization'
        # Mark ownership before building. Failed products are pruned only after
        # the child has exited; bounded private diagnostics survive separately.
        job=Path(tempfile.mkdtemp(prefix=f'build-{build}-',dir=BASE));output=job/'release';derived=job/'DerivedData'
        atomic(job/'job.json',dict(schema='cassini-mac-test-job@1',phase='building',build=build,head=head))
        env=dict(os.environ)
        state['job']=str(job);atomic(state_file,state)
        with (job/'release-driver.log').open('w') as log:
            release=[sys.executable,str(SOURCE/'scripts/release.py'),'--test-release','--version',version,
                '--build',str(build),'--output',str(output)]
            if external is None:
                release+=['--derived-data',str(derived)]
            else:
                # DerivedData goes to the external volume, which only the logged-in session can reach: its runner
                # starts the helper, and the helper makes, checks and removes the folder. Products stay in `job`.
                runner,root=external
                release=[runner,sys.executable,str(SOURCE/'scripts/external-derived-build.py'),root,*release]
            code=signed_build(release,env,log)
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
        identity=stage+':'+type(error).__name__+':'+slot+':'+str(manual or state.get('request',0))
        state.update(phase='failed')
        if state.get('failure')!=identity:
            cause=str(error).replace('\n',' ')[:180] if isinstance(error,(ValueError,RuntimeError)) else type(error).__name__
            report('[Mac] daily test release failed: '+stage+': '+cause)
        state['failure']=identity;atomic(state_file,state)
        if job is not None and not job.is_symlink() and job.is_dir():
            try:
                atomic(job/'job.json',dict(schema='cassini-mac-test-job@1',phase='failed',build=build,head=head,stage=stage))
                prune_failed_builds()
                state.pop('job',None);state['diagnostics']=str(BASE/'failures'/job.name)
                atomic(state_file,state)
            except (OSError,ValueError):
                report('[Mac] failed-job cleanup incomplete; inspect private job and diagnostics')
        raise SystemExit(1)


if __name__=='__main__':
    if BASE.resolve()!=BASE:
        raise SystemExit('Dedicated release storage must not follow symlinks')
    BASE.mkdir(parents=True,exist_ok=True);os.chmod(BASE,0o700)
    with (BASE/'scheduler.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise SystemExit(0)
        tick(datetime.now(timezone.utc))
