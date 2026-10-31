#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build a signed, notarized download locally. Does not publish or launch Cassini."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SECRETS = Path.home()/'.config/cassini/secrets'
TEAM = '4LS8W738Y3'
PRODUCT_NAME = next(entry['en'] for entry in json.loads((ROOT/'Cassini/Resources/UX/strings.json').read_text())['entries'] if entry['id'] == 'app.name')
BASE_URL = 'https://cassini.talk/download/mac'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def run(command, **kwargs):
    # Never emit commands: some Security invocations carry the local keychain
    # password. Never forward errors from key tools (invalid input can echo keys).
    result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        raise RuntimeError(Path(str(command[0])).name+' failed; exit '+str(result.returncode))
    return result.stdout


def private_file(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink() or stat.S_IMODE(path.stat().st_mode) != 0o600 or path.stat().st_uid != os.getuid():
        raise ValueError('Expected an owned, regular private file with mode0600')
    return path


def unlock_signing_keychain():
    keychain = private_file(SECRETS/'cassini-signing.keychain-db')
    password = private_file(SECRETS/'cassini-signing-keychain.password').read_text()
    run(['security', 'unlock-keychain', '-p', password, keychain], timeout=30)
    run(['security', 'set-keychain-settings', '-lut', '21600', keychain], timeout=30)
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain], timeout=30).decode()
    match = re.search(r'([0-9A-F]{40}) "Developer ID Application: Codemyriad OU \('+TEAM+r'\)"', identities)
    if not match:
        raise ValueError('Dedicated keychain has no valid Codemyriad Developer ID identity')
    return keychain, match.group(1)


def https_url(value):
    parts = urlparse(value)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.fragment or 'PLACEHOLDER' in value or parts.hostname.endswith('.invalid'):
        raise ValueError('Supply an approved HTTPS URL, without credentials, fragments or placeholders')
    return value


def release_urls(base_url, version):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version):
        raise ValueError('Expected a numeric release version')
    base = https_url(base_url).rstrip('/')
    parts = urlparse(base)
    if parts.query or parts.params or any(part in ('.', '..') for part in parts.path.split('/')):
        raise ValueError('Expected an HTTPS directory URL without a query or path traversal')
    return dict(base=base, feed=base+'/appcast.xml', download=base+'/Cassini-talk-'+version+'.dmg',
        latest=base+'/Cassini-talk.dmg', notes=base+'/notes/'+version+'.html')


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024*1024):
            digest.update(chunk)
    return digest.hexdigest()


def copy_new(source, destination):
    # A versioned artifact and a staging directory are never reused.
    with Path(source).open('rb') as source_file, Path(destination).open('xb') as target:
        shutil.copyfileobj(source_file, target)
    if Path(source).stat().st_size != Path(destination).stat().st_size or sha256_file(source) != sha256_file(destination):
        raise ValueError('Release copy differs from its signed source')


def verify_signature(path, signature, public_key=ROOT/'Distribution/sparkle-public-key.txt'):
    # Public-key verification needs neither the production seed nor a keychain.
    run(['xcrun', 'swift', ROOT/'scripts/verify-update-signature.swift', public_key, signature, path], timeout=180)


def publication_plan(output, urls, version, signature, notes=False):
    files = ['Cassini-talk-'+version+'.dmg', 'Cassini-talk.dmg', 'appcast.xml']
    if notes:
        files.append('notes/'+version+'.html')
    hashes = {name: sha256_file(output/name) for name in files}
    if hashes[files[0]] != hashes['Cassini-talk.dmg']:
        raise ValueError('Latest DMG differs from the immutable versioned DMG')
    size = (output/files[0]).stat().st_size
    steps = [dict(action='upload', file=files[0], url=urls['download'], overwrite=False),
        dict(action='verifyHTTPS', url=urls['download'], bytes=size, sha256=hashes[files[0]], edSignature=signature),
        dict(action='upload', file='Cassini-talk.dmg', url=urls['latest'], overwrite=True)]
    if notes:
        steps.append(dict(action='upload', file='notes/'+version+'.html', url=urls['notes'], overwrite=False))
    steps.append(dict(action='upload', file='appcast.xml', url=urls['feed'], overwrite=True))
    (output/'publication.json').write_text(json.dumps(dict(version=version, baseURL=urls['base'], steps=steps), indent=2)+'\n')
    (output/'SHA256SUMS').write_text(''.join(digest+'  '+name+'\n' for name, digest in hashes.items()))
    return hashes[files[0]]


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        https_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def verify_uploaded_download(output, public_key=ROOT/'Distribution/sparkle-public-key.txt', opener=None):
    # Read-only GET, invoked separately only after the immutable DMG is uploaded.
    # Never publish the latest alias or feed on the strength of a local check.
    report = json.loads((output/'release.json').read_text())
    urls = release_urls(report['baseURL'], report['version'])
    local = output/('Cassini-talk-'+report['version']+'.dmg')
    size = local.stat().st_size
    if size != report['bytes'] or sha256_file(local) != report['sha256']:
        raise ValueError('Local release no longer matches its report')
    verify_signature(local, report['edSignature'], public_key)
    opener = opener or urllib.request.build_opener(HTTPSRedirects())
    with tempfile.TemporaryDirectory(prefix='cassini-https-check-') as temporary:
        downloaded = Path(temporary)/'download.dmg'
        with opener.open(urls['download'], timeout=60) as response, downloaded.open('xb') as target:
            https_url(response.geturl())
            if response.status != 200:
                raise ValueError('Expected a complete HTTPS download')
            count = 0
            while chunk := response.read(min(1024*1024, size-count+1)):
                count += len(chunk)
                if count > size:
                    raise ValueError('HTTPS download exceeds the signed artifact length')
                target.write(chunk)
        if count != size or sha256_file(downloaded) != report['sha256']:
            raise ValueError('HTTPS download differs from the signed artifact')
        verify_signature(downloaded, report['edSignature'], public_key)
    return dict(url=urls['download'], bytes=size, sha256=report['sha256'], edSignatureVerified=True)


def notary_credentials(path):
    config = json.loads(private_file(path).read_text())
    key = private_file(Path(config['key']).expanduser())
    if not re.fullmatch(r'[A-Za-z0-9]+', config['keyId']) or not re.fullmatch(r'[0-9a-fA-F-]{36}', config['issuer']):
        raise ValueError('Invalid notarization API metadata')
    return ['--key', str(key), '--key-id', config['keyId'], '--issuer', config['issuer']]


def submit_and_wait(path, credentials, report):
    # Persist the submission ID before waiting: a timeout must not orphan a
    # still-running Apple submission or require another upload to discover it.
    result = json.loads(run(['xcrun', 'notarytool', 'submit', path, *credentials, '--output-format', 'json'], timeout=600))
    submission_id = result['id']
    report.write_text(json.dumps({k: result.get(k) for k in ['id', 'status', 'message']}, indent=2)+'\n')
    result = json.loads(run(['xcrun', 'notarytool', 'wait', submission_id, *credentials,
        '--timeout', '45m', '--output-format', 'json'], timeout=2800))
    report.write_text(json.dumps({k: result.get(k) for k in ['id', 'status', 'message']}, indent=2)+'\n')
    if result.get('status') != 'Accepted':
        raise ValueError('Notarization was not accepted; inspect the retained submission ID with notarytool')


def notarize(path, credentials, report):
    submit_and_wait(path, credentials, report)
    run(['xcrun', 'stapler', 'staple', path], timeout=180)
    run(['xcrun', 'stapler', 'validate', path], timeout=180)


def appcast(archive, signature, version, build, download_url, now=None, release_notes_url=None,
            release_notes_signature=None, release_notes_length=None):
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Invalid Ed25519 signature')
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = PRODUCT_NAME+' for Mac'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = PRODUCT_NAME+' '+version
    ET.SubElement(item, '{'+SPARKLE+'}version').text = str(build)
    ET.SubElement(item, '{'+SPARKLE+'}shortVersionString').text = version
    ET.SubElement(item, '{'+SPARKLE+'}minimumSystemVersion').text = '15.0'
    ET.SubElement(item, 'pubDate').text = format_datetime(now or datetime.now(timezone.utc))
    if release_notes_url:
        if not isinstance(release_notes_signature, str) or not re.fullmatch(r'[A-Za-z0-9+/]{86}==', release_notes_signature):
            raise ValueError('Linked release notes require an Ed25519 signature')
        if type(release_notes_length) is not int or release_notes_length <= 0:
            raise ValueError('Linked release notes require a positive byte length')
        ET.SubElement(item, '{'+SPARKLE+'}releaseNotesLink', {
            '{'+SPARKLE+'}edSignature': release_notes_signature,
            '{'+SPARKLE+'}length': str(release_notes_length)}).text = https_url(release_notes_url)
    elif release_notes_signature is not None or release_notes_length is not None:
        raise ValueError('Release-notes authentication needs a linked document')
    ET.SubElement(item, 'enclosure', {'url': https_url(download_url), 'length': str(archive.stat().st_size),
        'type': 'application/octet-stream', '{'+SPARKLE+'}edSignature': signature})
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)+b'\n'


def verify_release_notes(notes, signature, length, public_key=ROOT/'Distribution/sparkle-public-key.txt'):
    if type(length) is not int or length <= 0 or Path(notes).stat().st_size != length:
        raise ValueError('Release notes differ from their signed byte length')
    verify_signature(notes, signature, public_key)


def write_signed_appcast(output, archive, signature, version, build, urls, tools, key,
                         public_key=ROOT/'Distribution/sparkle-public-key.txt'):
    # SURequireSignedFeed authenticates linked HTML separately. Sign the final
    # staged bytes, put both namespaced attributes into XML, then sign the feed.
    notes = output/'notes'/(version+'.html')
    if notes.stat().st_size <= 0:
        raise ValueError('Release notes must not be empty')
    # Preserve the final HTML; Sparkle otherwise inserts a signing-warning comment.
    notes_signature = run([tools/'sign_update','--ed-key-file',key,'--disable-signing-warning','-p',notes],timeout=180).decode().strip()
    length = notes.stat().st_size
    run([tools/'sign_update','--verify','--ed-key-file',key,notes,notes_signature],timeout=180)
    verify_release_notes(notes, notes_signature, length, public_key)
    feed = output/'appcast.xml'
    feed.write_bytes(appcast(archive, signature, version, build, urls['download'],release_notes_url=urls['notes'],
        release_notes_signature=notes_signature,release_notes_length=length))
    run([tools/'sign_update','--ed-key-file',key,feed],timeout=180)
    run([tools/'sign_update','--verify','--ed-key-file',key,feed],timeout=180)
    verify_release_notes(notes, notes_signature, length, public_key)
    return dict(url=urls['notes'],bytes=length,edSignature=notes_signature,sha256=sha256_file(notes))


def verify_update_key(key):
    # Sparkle echoes malformed key input in one error path. Validate locally and
    # suppress every sign_update diagnostic rather than allowing secret output.
    import base64
    raw = base64.b64decode(private_file(key).read_text().strip(), validate=True)
    if len(raw) != 32:
        raise ValueError('Expected a32-byte Sparkle signing seed')
    return key


def reject_generated_library(path):
    # A prior screenshot build can leave these generated fixtures in the
    # source tree or the incremental Release product. Never upload them.
    if path.exists() or path.is_symlink():
        raise ValueError('Generated Library fixtures are present; use a clean release source/product')


def dmg_tools():
    requirements = ROOT/'Distribution/dmg-requirements.txt'
    pin = hashlib.sha256(requirements.read_bytes()).hexdigest()[:16]
    environment = ROOT/'.build'/('dmg-tools-'+pin+'-'+str(sys.version_info.major)+'.'+str(sys.version_info.minor))
    python = environment/'bin/python3'
    marker = environment/'installed'
    interpreter = pin+'\n'+sys.version+'\n'+str(Path(sys.executable).resolve())+'\n'
    if not python.is_file() or not marker.is_file() or marker.read_text() != interpreter:
        # A restored hosted cache may point at a different runner's Python.
        # Rebuild the environment while keeping the verified download cache.
        run([sys.executable, '-m', 'venv', '--clear', environment], timeout=120)
        run([python, '-m', 'pip', 'install', '--disable-pip-version-check', '--require-hashes', '--only-binary=:all:',
             '--cache-dir', ROOT/'.build/dmg-pip-cache', '-r', requirements], timeout=180)
        marker.write_text(interpreter)
    return python


def build_dmg(python, application, output):
    run([python, ROOT/'scripts/build-dmg.py', application, output], timeout=600)


def release(args):
    urls = release_urls(args.base_url, args.version)
    if args.build < 1:
        raise ValueError('Expected a numeric version and positive increasing build number')
    if not args.release_notes or not args.release_notes.is_file() or args.release_notes.stat().st_size == 0:
        raise ValueError('Release notes must name an existing HTML file')
    # Refuse to overwrite or mix artifacts from earlier builds/submissions.
    output = args.output.resolve()
    if output.exists():
        raise ValueError('Release output already exists; use a new empty destination')
    reject_generated_library(ROOT/'UITests/Fixtures/Library')
    credentials = notary_credentials(args.notary_config)
    key = verify_update_key(SECRETS/'sparkle-ed25519.key')
    run(['xcrun', 'swift', ROOT/'scripts/check-update-key.swift', key, ROOT/'Distribution/sparkle-public-key.txt'], timeout=60)
    keychain, identity = unlock_signing_keychain()
    output.mkdir(parents=True)
    tools = Path(run(['python3', ROOT/'scripts/fetch-sparkle.py', '--output', ROOT/'.build/Sparkle']).decode().strip())/'bin'
    image_tools = dmg_tools()
    run(['xcodegen', 'generate'], cwd=ROOT, timeout=120)
    run(['python3', ROOT/'browser-protocol/verify.py', '--pinned', ROOT/'BrowserExtension'], timeout=60)
    derived = ROOT/'.build/developer-id'
    command = ['xcodebuild', 'build', '-project', 'Cassini.xcodeproj', '-scheme', 'Cassini', '-configuration', 'Release',
        '-derivedDataPath', derived, '-jobs', '2', 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY='+identity, 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM='+TEAM,
        'CASSINI_APP_HARDENED_RUNTIME=YES', 'MARKETING_VERSION='+args.version, 'CURRENT_PROJECT_VERSION='+str(args.build),
        'CASSINI_UPDATE_FEED='+urls['feed'], 'CASSINI_UPDATES_ENABLED=YES']
    # Build logs contain no password/ASC metadata; retain diagnostics for review.
    with (output/'build.log').open('wb') as log:
        result = subprocess.run(list(map(str,command)), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError('Release build failed; inspect build.log')
    # Xcode's internal product/executable paths stay stable for developer tools.
    # The application submitted to Apple and delivered to people has its final
    # Finder name before notarization, so Sparkle never renames an installation.
    app = output/(PRODUCT_NAME+'.app')
    run(['ditto', derived/'Build/Products/Release/Cassini.app', app])
    reject_generated_library(app/'Contents/Resources/Fixtures/Library')
    run(['python3', ROOT/'scripts/check-signing-identifiers.py', app, '--require-hardened-runtime'])
    run(['python3', ROOT/'scripts/check-developer-id.py', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    # No post-build re-signing: worker manifests already bind signed bytes.
    submission = output/'Cassini-talk-notary.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, submission])
    # ZIPs cannot be stapled. Submit the zip, then staple its original app.
    submit_and_wait(submission, credentials, output/'app-notary.json')
    run(['xcrun', 'stapler', 'staple', app], timeout=180)
    run(['xcrun', 'stapler', 'validate', app], timeout=180)
    dmg = output/('Cassini-talk-'+args.version+'.dmg')
    build_dmg(image_tools, app, dmg)
    run(['codesign', '--sign', identity, '--keychain', keychain, '--timestamp', dmg], timeout=180)
    notarize(dmg, credentials, output/'dmg-notary.json')
    run(['codesign', '--verify', '--strict', dmg])
    signature = run([tools/'sign_update', '--ed-key-file', key, '-p', dmg], timeout=180).decode().strip()
    run([tools/'sign_update', '--verify', '--ed-key-file', key, dmg, signature], timeout=180)
    verify_signature(dmg, signature)
    copy_new(dmg, output/'Cassini-talk.dmg')
    verify_signature(output/'Cassini-talk.dmg', signature)
    (output/'notes').mkdir()
    copy_new(args.release_notes, output/'notes'/(args.version+'.html'))
    notes_report = write_signed_appcast(output,dmg,signature,args.version,args.build,urls,tools,key)
    checksum = publication_plan(output, urls, args.version, signature, notes=True)
    (output/'release.json').write_text(json.dumps(dict(commit=run(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(),
        version=args.version, build=args.build, baseURL=urls['base'], bytes=dmg.stat().st_size,
        edSignature=signature, sha256=checksum, releaseNotes=notes_report, notarized=True, cleanVMChecked=False),indent=2)+'\n')
    print('Notarized and stapled '+dmg.name+' and identical Cassini-talk.dmg; SHA256 '+checksum)
    print('Clean-VM install/browser/update checks and publication are still required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--base-url', default=BASE_URL, help='HTTPS directory for downloads, feed and optional notes')
    parser.add_argument('--release-notes', type=Path, required=True, help='HTML release notes, copied into notes/<version>.html')
    parser.add_argument('--notary-config', type=Path, default=SECRETS/'notary.json')
    parser.add_argument('--output', type=Path, required=True)
    try:
        release(parser.parse_args())
    except (ValueError, RuntimeError, OSError, KeyError, TypeError, subprocess.TimeoutExpired):
        # Do not interpolate tool exceptions: argv may contain a keychain password.
        parser.exit(1, 'Release failed. Check private credentials, signing identity and retained build/submission reports.\n')
