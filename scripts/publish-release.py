#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Publish a completed release to https://cassini.talk/download/mac/ (D34.1).

Runs the ordered publication.json that release.py wrote, with rclone, into the
Mac-owned bucket prefix download/mac/ only. It never syncs, deletes, moves or
touches anything outside that prefix (the site's index.html and 404.html stay
coordinator-owned). The versioned DMG is uploaded immutably and verified over
HTTPS before the latest copy, the release notes and, last, the appcast.
Before any upload it reads the appcast deployed in the bucket and refuses a
lower version or a build that is not higher; only a byte-identical retry of the
deployed release is allowed.

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
import xml.etree.ElementTree as ET

SITE = 'https://cassini.talk/download/mac'
REMOTE = 'cassinitalk:cassini-talk/'
PREFIX = 'download/mac/'
ENV = Path.home()/'.config/cassini-talk/r2.env'
# rclone subcommands this script may run; anything that can delete is absent.
ALLOWED = {'copyto', 'lsf', 'cat'}
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def bucket_key(url):
    # Only https://cassini.talk/download/mac/<name> maps, to download/mac/<name>.
    if not url.startswith(SITE+'/'):
        raise ValueError('Refusing a URL outside '+SITE+'/: '+url)
    rest = url[len(SITE)+1:]
    if not re.fullmatch(r'[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*', rest) or any(part in ('.', '..') for part in rest.split('/')):
        raise ValueError('Refusing an unexpected release path: '+url)
    return PREFIX+rest


def rclone(arguments, env=ENV, runner=subprocess.run, binary=False):
    if arguments[0] not in ALLOWED:
        raise ValueError('Refusing rclone '+arguments[0])
    for argument in arguments[1:]:
        if argument.startswith(REMOTE) and not argument.startswith(REMOTE+PREFIX):
            raise ValueError('Refusing a remote path outside '+PREFIX)
    # The env file is sourced only inside this shell; its values never reach our argv or output.
    command = ['sh', '-c', 'set -a; . "$0"; set +a; exec rclone "$@"', str(env), *arguments]
    result = runner(command, capture_output=True, text=not binary, timeout=3600)
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
    if plan['version'] != report['version'] or report.get('notarized') is not True or not isinstance(report.get('build'), int):
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


def version_key(version):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', str(version)):
        raise ValueError('Unexpected version '+repr(version))
    parts = [int(part) for part in str(version).split('.')]
    while parts and parts[-1] == 0:
        parts.pop()
    return parts


def feed_release(feed):
    """(version, build) of the newest item in a Sparkle appcast."""
    items = []
    try:
        root = ET.fromstring(feed)
    except ET.ParseError:
        raise ValueError('An appcast is not well-formed XML') from None
    for item in root.iter('item'):
        version, build = item.findtext(SPARKLE+'shortVersionString'), item.findtext(SPARKLE+'version')
        if version is None or build is None or not re.fullmatch(r'[0-9]+', build.strip()):
            raise ValueError('The deployed appcast has an item without a version and numeric build')
        items.append((version.strip(), int(build)))
    if not items:
        raise ValueError('The deployed appcast has no release')
    return max(items, key=lambda item: item[1])


def deployed(env=ENV, runner=subprocess.run):
    """The appcast in the bucket (not the CDN, which may serve an older copy) or None, and the
    versions of the versioned DMGs already there. An rclone error stops the publish."""
    listed = (rclone(['lsf', REMOTE+PREFIX, '--files-only', '--max-depth', '1'], env=env, runner=runner).stdout or '').splitlines()
    versions = [match.group(1) for name in listed if (match := re.fullmatch(r'Cassini-talk-([0-9]+(?:\.[0-9]+)*)\.dmg', name))]
    feed = rclone(['cat', REMOTE+PREFIX+'appcast.xml'], env=env, runner=runner, binary=True).stdout if 'appcast.xml' in listed else None
    return feed, versions


def check_against_deployed(output, report, deployed, dmg_versions=()):
    """Sparkle only offers a higher build, and an older upload would roll back latest and the feed.
    Refuse a lower version or a build that is not higher, unless this is a byte-identical retry."""
    local = (output/'appcast.xml').read_bytes()
    version, build = report['version'], int(report['build'])
    # Compare what is actually uploaded: the signed feed must announce release.json's release.
    if feed_release(local) != (version, build):
        raise ValueError('The local appcast does not announce '+version+' ('+str(build)+') as release.json says')
    # A publish that stopped after the latest copy leaves a newer versioned DMG than the feed.
    newer = [other for other in dmg_versions if version_key(other) > version_key(version)]
    if newer:
        raise ValueError('Refusing to publish '+version+': the bucket already holds the newer Cassini-talk-'+max(newer, key=version_key)+'.dmg')
    if deployed is None:
        return 'no deployed appcast; this is the first release'
    if isinstance(deployed, str):
        deployed = deployed.encode()
    live_version, live_build = feed_release(deployed)
    if deployed == local:
        return 'deployed appcast is byte-identical to '+version+' ('+str(build)+'); retrying'
    if version_key(version) < version_key(live_version):
        raise ValueError('Refusing to publish '+version+' ('+str(build)+') over the deployed '+live_version+' ('+str(live_build)+'): lower version')
    if build <= live_build:
        raise ValueError('Refusing to publish '+version+' ('+str(build)+') over the deployed '+live_version+' ('+str(live_build)+'): the build must be higher, or Sparkle never offers it')
    return 'deployed '+live_version+' ('+str(live_build)+') is older than '+version+' ('+str(build)+')'


def publish(output, dry_run=True, env=ENV, runner=subprocess.run, verify=None, log=print):
    plan, report = load(output)
    # Read-only and before any upload, in a dry run too.
    log(check_against_deployed(output, report, *deployed(env=env, runner=runner)))
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
