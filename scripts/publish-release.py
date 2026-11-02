#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Publish a completed release to https://cassini.talk/download/mac/ (D34.1).

Runs the ordered publication.json that release.py wrote, with rclone, into the
Mac-owned bucket prefix download/mac/ only. It never syncs, deletes, moves or
touches anything outside that prefix (the site's index.html and 404.html stay
coordinator-owned). The versioned DMG is uploaded immutably and verified over
HTTPS before the latest copy, the release notes and, last, the appcast.

A dry run is the default: rclone --dry-run reports each copy and changes
nothing. Uploading is public at once, so it needs --publish <version> and
--clean-vm-qa-passed, and only after Mac QA has passed and the coordinator has
confirmed the release. Credentials are sourced from ~/.config/cassini-talk/r2.env
inside sh -c and are never read, printed or passed on the command line here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

SITE = 'https://cassini.talk/download/mac'
REMOTE = 'cassinitalk:cassini-talk/'
PREFIX = 'download/mac/'
ENV = Path.home()/'.config/cassini-talk/r2.env'
# rclone subcommands this script may run; anything that can delete is absent.
ALLOWED = {'copyto', 'lsf'}


def bucket_key(url):
    # Only https://cassini.talk/download/mac/<name> maps, to download/mac/<name>.
    if not url.startswith(SITE+'/'):
        raise ValueError('Refusing a URL outside '+SITE+'/: '+url)
    rest = url[len(SITE)+1:]
    if not re.fullmatch(r'[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*', rest) or any(part in ('.', '..') for part in rest.split('/')):
        raise ValueError('Refusing an unexpected release path: '+url)
    return PREFIX+rest


def rclone(arguments, env=ENV, runner=subprocess.run):
    if arguments[0] not in ALLOWED:
        raise ValueError('Refusing rclone '+arguments[0])
    for argument in arguments[1:]:
        if argument.startswith(REMOTE) and not argument.startswith(REMOTE+PREFIX):
            raise ValueError('Refusing a remote path outside '+PREFIX)
    # The env file is sourced only inside this shell; its values never reach our argv or output.
    command = ['sh', '-c', 'set -a; . "$0"; set +a; exec rclone "$@"', str(env), *arguments]
    result = runner(command, capture_output=True, text=True, timeout=3600)
    if result.returncode != 0:
        raise RuntimeError('rclone '+arguments[0]+' failed (exit '+str(result.returncode)+')')
    return result


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024*1024):
            digest.update(chunk)
    return digest.hexdigest()


def load(output):
    plan = json.loads((output/'publication.json').read_text())
    report = json.loads((output/'release.json').read_text())
    if plan['baseURL'] != SITE or report['baseURL'] != SITE:
        raise ValueError('This release was built for another base URL; rebuild it for '+SITE)
    if plan['version'] != report['version'] or report.get('notarized') is not True:
        raise ValueError('publication.json and release.json disagree, or the release is not notarized')
    sums = dict(reversed(line.split('  ', 1)) for line in (output/'SHA256SUMS').read_text().splitlines())
    uploads = [step for step in plan['steps'] if step['action'] == 'upload']
    if not uploads or uploads[-1]['file'] != 'appcast.xml' or plan['steps'][1]['action'] != 'verifyHTTPS':
        raise ValueError('Unexpected publication order: the DMG is verified second and the appcast goes last')
    for step in uploads:
        local = (output/step['file']).resolve()
        if output.resolve() not in local.parents or sums.get(step['file']) != sha256_file(local):
            raise ValueError('Local file differs from SHA256SUMS: '+step['file'])
        bucket_key(step['url'])
    return plan, report


def publish(output, dry_run=True, env=ENV, runner=subprocess.run, verify=None, log=print):
    plan, report = load(output)
    for step in plan['steps']:
        if step['action'] == 'verifyHTTPS':
            if dry_run:
                log('would verify '+step['url']+' over HTTPS before the latest copy and the appcast')
                continue
            checked = verify(output)
            if checked['sha256'] != step['sha256'] or checked['bytes'] != step['bytes'] or not checked.get('edSignatureVerified'):
                raise ValueError('HTTPS download differs from the plan')
            log('verified '+step['url'])
            continue
        if step['action'] != 'upload':
            raise ValueError('Unknown publication step '+step['action'])
        key = bucket_key(step['url'])
        # --immutable: an existing versioned file is never replaced (an identical one is skipped).
        arguments = ['copyto', str(output/step['file']), REMOTE+key] + ([] if step['overwrite'] else ['--immutable'])
        rclone(arguments + (['--dry-run'] if dry_run else []), env=env, runner=runner)
        log(('would upload ' if dry_run else 'uploaded ')+step['file']+' to '+step['url'])
    return report['version']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path, help='Completed release directory from release.py')
    parser.add_argument('--publish', metavar='VERSION', help='Upload for real; must equal the release version')
    parser.add_argument('--clean-vm-qa-passed', action='store_true', help='Mac QA passed on this exact DMG in a clean VM')
    args = parser.parse_args()
    try:
        plan, _ = load(args.output)
        live = args.publish is not None
        if live and (args.publish != plan['version'] or not args.clean_vm_qa_passed):
            parser.exit(2, 'Refusing to publish: pass --publish '+plan['version']+' and --clean-vm-qa-passed only after QA and approval.\n')
        if live:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import release
            verify = release.verify_uploaded_download
        else:
            verify = None
        publish(args.output, dry_run=not live, verify=verify)
        print(('Published ' if live else 'Dry run complete for ')+plan['version']+' under '+SITE+'/')
    except (ValueError, RuntimeError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, 'Publishing stopped: '+str(error)+'\n')
