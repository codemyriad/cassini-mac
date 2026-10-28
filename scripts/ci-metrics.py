#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only GitHub Actions measurements for one push/dispatch, with raw evidence."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import statistics
import subprocess


def api(path):
    return json.loads(subprocess.check_output(['gh','api',path],text=True))


def stamp(value):
    return datetime.fromisoformat(value.replace('Z','+00:00')) if value else None


def summarize(runs, jobs):
    actual = [j for j in jobs if j.get('runner_name') and j.get('conclusion') != 'skipped']
    mac = [j for j in actual if any('macos' in label.lower() for label in j.get('labels', []))]
    duration = lambda j: max(0,(stamp(j['completed_at'])-stamp(j['started_at'])).total_seconds())
    finished = [j for j in mac if j.get('started_at') and j.get('completed_at')]
    queues = [max(0,(stamp(j['started_at'])-stamp(j['created_at'])).total_seconds()) for j in mac if j.get('started_at') and j.get('created_at')]
    done = all(r['status']=='completed' for r in runs)
    start = min(stamp(r['created_at']) for r in runs)
    end = max(stamp(r['updated_at']) for r in runs)
    return dict(runs=len(runs),scheduled_jobs=len(jobs),executed_jobs=len(actual),executed_macos_jobs=len(mac),
                completed=done,conclusions={str(r['id']):r['conclusion'] for r in runs},
                macos_minutes_estimated=sum(math.ceil(duration(j)/60) for j in finished),
                macos_execution_minutes=round(sum(duration(j) for j in finished)/60,2),
                median_macos_queue_seconds=round(statistics.median(queues),1) if queues else None,
                wall_minutes=round((end-start).total_seconds()/60,2),
                note='Estimated billed macOS minutes round each executed job up to a minute; excludes storage, rates, credits and billing adjustments. Cancelled jobs count only if assigned to a runner. Wall time ends at last run update.')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo',default='codemyriad/cassini-mac');p.add_argument('--sha');p.add_argument('--run',type=int,action='append');p.add_argument('--event',default='pull_request');p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();prefix='repos/'+a.repo+'/actions'
    if a.run:
        runs=[api(prefix+'/runs/'+str(run)) for run in a.run]
    elif a.sha:
        runs=api(prefix+'/runs?head_sha='+a.sha+'&event='+a.event+'&per_page=100')['workflow_runs']
    else:p.error('Specify --sha or --run')
    if not runs:p.error('No matching runs')
    jobs=[]
    for run in runs:
        page=1
        while True:
            batch=api(prefix+'/runs/'+str(run['id'])+'/jobs?filter=latest&per_page=100&page='+str(page))['jobs']
            jobs.extend(batch)
            if len(batch)<100:break
            page+=1
    result=dict(summary=summarize(runs,jobs),runs=runs,jobs=jobs)
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result['summary'],indent=2))

if __name__=='__main__':main()
