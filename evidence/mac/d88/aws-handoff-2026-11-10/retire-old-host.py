"""Old-host-only final handoff: stop periodic writers, audit, push, then exit."""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import json
import os
import signal
import subprocess
import time

ARCHIVE = Path(__file__).resolve().parent
HOME = Path.home()
START = datetime(2026, 11, 11, 8, 20, tzinfo=timezone.utc)
END = datetime(2026, 11, 11, 8, 28, tzinfo=timezone.utc)


def now():
    return datetime.now(timezone.utc)


def command(args, timeout=45, env=None):
    remaining = (END-now()).total_seconds()
    if remaining <= 0:
        raise RuntimeError('Finalization time budget ended; no more old-host commands')
    child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, env=env, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=min(timeout, remaining))
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
        raise RuntimeError('Timed out: '+str(args[:3])+' '+output[-500:])
    if child.returncode:
        raise RuntimeError('Command failed: '+str(args[:3])+' '+output[-1000:])
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='Exact old-host uname nodename')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.host != os.uname().nodename:
        raise RuntimeError('Refusing old-host retirement on a replacement host')
    print(json.dumps(dict(host=args.host, finalizeAt=START.isoformat(),
                          commandsEndBy=END.isoformat())), flush=True)
    if args.check:
        return
    while now() < START:
        time.sleep(min(30, (START-now()).total_seconds()))
    if now() >= END:
        print('Cutoff already passed; refusing further old-host operations', flush=True)
        return
    # These are this task's sessions only; leave CI runners and other agents alone.
    for session in ('aws-mac-d88-ci', 'aws-mac-d88-checkpoint'):
        try:
            command(['tmux', 'kill-session', '-t', session], timeout=5)
        except RuntimeError as error:
            print(str(error), flush=True)  # A completed watcher may already be gone.
    audit_error = None
    env = dict(os.environ, AWS_MAC_RETIRE_AT='2026-11-11T08:24:00+00:00')
    try:
        output = command(['python3', str(HOME/'coordination/AWS-MAC-CI-WATCH.py'),
                          '--mark-ready'], timeout=60, env=env)
        (ARCHIVE/'final-ci-audit.log').write_text(output)
    except RuntimeError as error:
        audit_error = str(error)
    data = json.loads((HOME/'CI-AWS-MAC.json').read_text())
    heads = json.loads((ARCHIVE/'routing-heads.json').read_text())
    status = (HOME/'STATUS-AWS-MAC.md').read_text().split('\n## Final handoff — old host stopped\n')[0]
    status += '\n## Final handoff — old host stopped\n\nRecorded: '+now().isoformat(timespec='seconds')+'\n\n'
    status += ('Periodic readiness/checkpoint sessions stopped. This final audit/checkpoint is the last old-host operation; '
               'no further use after 08:30 UTC. Mac termination/disk deletion: 2026-11-11 09:30 UTC.\n\n')
    status += ('Pushed: all six implementation branches and mutation evidence, merged-main local validation logs, '
               'shared supersession proof branch, #222 path-fencing proof (merged through #208), and operational '
               'handoff scripts on `test/d88-aws-handoff`. No credentials/build caches are needed.\n\n')
    status += 'Last CI observation: '+data['updated']+'\n\n'
    for item in data['prs']:
        state = (item['state'].lower() if item.get('state') in ('MERGED', 'CLOSED') else
                 'ready' if not item['draft'] else
                 'failed: '+', '.join(item['failed']) if item['failed'] else
                 'green; final readiness audit pending' if item['readyCandidate'] else
                 'pending: '+', '.join(item['pending']))
        if not item['headMatches']:
            state += '; head differs from the locally validated watcher head'
        status += f"- #{item['pr']} `{item['head']}`: {state}.\n"
        lines=status.splitlines()
        for i,line in enumerate(lines):
            if line.startswith('|') and f"[#{item['pr']}]" in line:
                lines[i]=line.rsplit('|', 2)[0]+'| Local pass; '+state+' |'
        status='\n'.join(lines)+'\n'
    if audit_error:
        status += '\nFinal refresh error (last successful snapshot retained): '+audit_error+'\n'
    status += ('\nRemaining: on the replacement Mac, fetch the handoff branch and resume `ci-watch.py --watch --mark-ready` '
               'for any still-draft PRs after checking their exact heads against `routing-heads.json`. '
               'Report failed CI to the coordinator; no additional source work is authorized by this handoff. '
               'Leave AWS_MAC_RETIRE_AT unset on the replacement; do not start this old-host retirement timer there. '
               'Source restoration requires the branches, not this disk.\n')
    status += '\nValidated implementation heads: '+json.dumps(heads, sort_keys=True)+'\n'
    (HOME/'STATUS-AWS-MAC.md').write_text(status)
    # Bounded ordinary-push retries; never pull, merge, force-push, or run after END.
    while now() < END:
        try:
            output = command(['python3', str(ARCHIVE/'checkpoint.py')], timeout=60)
            repo = ARCHIVE.parents[3]
            local = command(['git', '-C', str(repo), 'rev-parse', 'HEAD']).strip()
            remote = command(['git', '-C', str(repo), 'ls-remote', 'origin',
                              'refs/heads/test/d88-aws-handoff']).split()[0]
            if local != remote:
                raise RuntimeError('Final handoff remote head differs')
            print(output, flush=True)
            print('FINAL HANDOFF PUSHED '+local+'; old-host work ended', flush=True)
            return
        except RuntimeError as error:
            print('FINAL CHECKPOINT RETRY: '+str(error), flush=True)
            remaining = (END-now()).total_seconds()
            if remaining > 0:
                time.sleep(min(15, remaining))
    print('Final push could not be verified before cutoff; stopping old-host use', flush=True)


if __name__ == '__main__':
    main()
