"""Checkpoint only this task's public handoff artifacts onto its own branch."""
from datetime import datetime, timezone
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import time

archive = Path(__file__).resolve().parent
repo = archive.parents[3]
branch = 'test/d88-aws-handoff'
home = Path.home()


def git(*args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def checkpoint():
    if git('branch', '--show-current') != branch:
        raise RuntimeError('Refusing checkpoint outside the dedicated handoff branch')
    if git('remote', 'get-url', 'origin') != 'https://github.com/codemyriad/cassini-mac.git':
        raise RuntimeError('Unexpected handoff origin')
    files = {
        home / 'STATUS-AWS-MAC.md': archive / 'STATUS-AWS-MAC.md',
        home / 'CI-AWS-MAC.json': archive / 'ci-snapshot.json',
        home / 'coordination/aws-mac-ci-watch.log': archive / 'ci-watch.log',
        home / 'coordination/aws-mac-test.py': archive / 'run-heavy.py',
    }
    for source, target in files.items():
        if source.exists():
            shutil.copyfile(source, target)
    for source in home.glob('READY-AWS-MAC-*.json'):
        if int(source.stem.rsplit('-', 1)[-1]) in range(210, 216):
            shutil.copyfile(source, archive / source.name)
    watch_source = home / 'coordination/AWS-MAC-CI-WATCH.py'
    if not watch_source.exists():
        watch_source = archive / 'ci-watch.py'
    source = watch_source.read_text()
    source = source.replace('import datetime,json,pathlib,re,subprocess,time,sys\n',
                            'import datetime,json,pathlib,re,subprocess,time,sys,os\n')
    if 'repo_path=os.environ.get' not in source:
        source = source.replace('prs={', 'repo_path=os.environ.get("CASSINI_MAC_REPO",str(pathlib.Path.home()/"agents/cassini-mac"))\nprs={', 1)
    source = source.replace("cwd='/Users/ec2-user/agents/cassini-mac'", 'cwd=repo_path')
    (archive / 'ci-watch.py').write_text(source)
    gate_source = home / 'coordination/test-aws-mac-ready-gates.py'
    if not gate_source.exists():
        gate_source = archive / 'test-ready-gates.py'
    source = gate_source.read_text()
    source = source.replace("(pathlib.Path.home()/'coordination/AWS-MAC-CI-WATCH.py')", "pathlib.Path(__file__).with_name('ci-watch.py')")
    (archive / 'test-ready-gates.py').write_text(source)
    paths = [str(p.relative_to(repo)) for p in archive.iterdir()
             if p.is_file() and p.suffix in ('.md', '.py', '.json', '.log')]
    git('add', '--', *paths)
    changed = subprocess.run(['git', '-C', str(repo), 'diff', '--cached', '--quiet']).returncode
    if changed == 1:
        git('diff', '--cached', '--check')
        git('commit', '-m', 'chore: checkpoint AWS Mac D88 migration status')
    elif changed != 0:
        raise RuntimeError('Cannot inspect checkpoint changes')
    # Ordinary push only. Remote changes cause a visible failure, never an overwrite.
    git('push', 'origin', 'HEAD:refs/heads/' + branch)
    stamp = datetime.now(timezone.utc).isoformat(timespec='seconds')
    print(json.dumps({'updated': stamp, 'head': git('rev-parse', 'HEAD')}), flush=True)


while True:
    stop_at=os.environ.get('AWS_MAC_RETIRE_AT')
    if '--watch' in sys.argv and stop_at and datetime.now(timezone.utc)>=datetime.fromisoformat(stop_at):
        print('Old AWS Mac checkpoint cutoff reached',flush=True);break
    try:
        checkpoint()
    except Exception as error:
        print('CHECKPOINT ERROR: ' + str(error), flush=True)
        if '--watch' not in sys.argv:
            raise
    if '--watch' not in sys.argv:
        break
    time.sleep(300)
