#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure files/XML and cryptographic CLI checks; no app/desktop/device execution."""
import base64
from datetime import datetime, timezone
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT/'scripts/release.py')
release = importlib.util.module_from_spec(spec);spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def testMissingNotesFailBeforeCredentialsOrBuild(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = SimpleNamespace(base_url=release.BASE_URL, version='1.0', build=2,
                release_notes=root/'missing.html', output=root/'new-output')
            with patch.object(release, 'notary_credentials') as credentials:
                with self.assertRaises(ValueError): release.release(args)
            credentials.assert_not_called()
            self.assertFalse(args.output.exists())

    def testApprovedLayoutAndConfigurableBase(self):
        self.assertEqual(release.release_urls(release.BASE_URL+'/', '0.1.2'), dict(
            base='https://cassini.talk/download/mac', feed='https://cassini.talk/download/mac/appcast.xml',
            download='https://cassini.talk/download/mac/Cassini-0.1.2.dmg', latest='https://cassini.talk/download/mac/Cassini.dmg',
            notes='https://cassini.talk/download/mac/notes/0.1.2.html'))
        self.assertEqual(release.release_urls('https://fixture.example/other', '2.0')['feed'], 'https://fixture.example/other/appcast.xml')
        for base in ['http://example.org/mac', 'https://u:p@example.org/mac', 'https://example.org/mac?x=1', 'https://example.org/../mac']:
            with self.assertRaises(ValueError): release.release_urls(base, '1.0')
        for version in ['../x', '1/2', '1', '1.0-beta', '١.٢']:
            with self.assertRaises(ValueError): release.release_urls(release.BASE_URL, version)

    def testPublicationOrderAndImmutableLocalCopies(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            versioned = output/'Cassini-1.0.dmg'; versioned.write_bytes(b'signed archive fixture')
            release.copy_new(versioned, output/'Cassini.dmg')
            with self.assertRaises(FileExistsError): release.copy_new(versioned, output/'Cassini.dmg')
            (output/'notes').mkdir(); (output/'notes/1.0.html').write_text('<p>Notes</p>')
            (output/'appcast.xml').write_bytes(b'<rss/>')
            release.publication_plan(output, release.release_urls(release.BASE_URL, '1.0'), '1.0', 'A'*86+'==', notes=True)
            plan = json.loads((output/'publication.json').read_text())
            self.assertEqual([(s['action'], s.get('file')) for s in plan['steps']], [
                ('upload','Cassini-1.0.dmg'), ('verifyHTTPS',None), ('upload','Cassini.dmg'),
                ('upload','notes/1.0.html'), ('upload','appcast.xml')])
            self.assertFalse(plan['steps'][0]['overwrite'])
            self.assertEqual(plan['steps'][1]['bytes'], len(b'signed archive fixture'))
            self.assertEqual(plan['steps'][1]['sha256'], release.sha256_file(versioned))
            sums = dict(line.split('  ', 1)[::-1] for line in (output/'SHA256SUMS').read_text().splitlines())
            self.assertEqual(sums['Cassini-1.0.dmg'], sums['Cassini.dmg'])
            (output/'Cassini.dmg').write_bytes(b'other bytes')
            with self.assertRaises(ValueError):
                release.publication_plan(output, release.release_urls(release.BASE_URL, '1.0'), '1.0', 'A'*86+'==')

    def testOptionalNotesAreLinkedOnlyWhenPresent(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary)/'Cassini-1.0.dmg'; archive.write_bytes(b'fixture')
            args = (archive, 'A'*86+'==', '1.0', 2, release.release_urls(release.BASE_URL, '1.0')['download'])
            tag = 'channel/item/{'+release.SPARKLE+'}releaseNotesLink'
            self.assertIsNone(ET.fromstring(release.appcast(*args)).find(tag))
            notes = 'https://cassini.talk/download/mac/notes/1.0.html'
            self.assertEqual(ET.fromstring(release.appcast(*args, release_notes_url=notes)).find(tag).text, notes)

    def testHTTPSRedirectCannotDowngrade(self):
        from urllib.request import Request
        request = Request('https://cassini.talk/download/mac/Cassini-1.0.dmg')
        with self.assertRaises(ValueError):
            release.HTTPSRedirects().redirect_request(request, None, 302, 'Found', {}, 'http://example.org/archive')
        redirected = release.HTTPSRedirects().redirect_request(request, None, 302, 'Found', {}, 'https://cdn.example.org/archive')
        self.assertEqual(redirected.full_url, 'https://cdn.example.org/archive')

    def testReadOnlyHTTPSVerificationUsesPublicKeyAndRejectsBadBytes(self):
        import subprocess
        tools = ROOT/'.build/Sparkle/distribution/bin/sign_update'
        if not tools.exists(): self.skipTest('Fetch pinned Sparkle tools before this cryptographic check')
        class Response(io.BytesIO):
            status = 200
            def geturl(self): return 'https://cassini.talk/download/mac/Cassini-1.0.dmg'
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); data = b'actual signed fixture bytes'
            archive = folder/'Cassini-1.0.dmg'; archive.write_bytes(data)
            seed = folder/'seed'; public = folder/'public'
            seed.write_text(base64.b64encode(bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')).decode()); seed.chmod(0o600)
            public.write_text('11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=')
            signature = subprocess.run([str(tools),'--ed-key-file',str(seed),'-p',str(archive)],capture_output=True,text=True,check=True).stdout.strip()
            report = dict(version='1.0', baseURL=release.BASE_URL, bytes=len(data), sha256=release.sha256_file(archive), edSignature=signature)
            (folder/'release.json').write_text(json.dumps(report))
            opener = Mock(); opener.open.return_value = Response(data)
            checked = release.verify_uploaded_download(folder, public, opener)
            self.assertTrue(checked['edSignatureVerified'])
            opener.open.assert_called_once_with('https://cassini.talk/download/mac/Cassini-1.0.dmg', timeout=60)
            # No private seed is needed by either verifier after signing.
            seed.unlink()
            for damaged in [data[:-1], b'x'+data[1:], data+b'extra']:
                opener = Mock(); opener.open.return_value = Response(damaged)
                with self.assertRaises(ValueError): release.verify_uploaded_download(folder, public, opener)
            # Changing both local bytes and the report's hash still cannot
            # launder them into a valid artifact without the Ed25519 signature.
            archive.write_bytes(b'x'+data[1:]); report['sha256'] = release.sha256_file(archive)
            (folder/'release.json').write_text(json.dumps(report)); opener = Mock()
            with self.assertRaises(RuntimeError): release.verify_uploaded_download(folder, public, opener)
            opener.open.assert_not_called()

    def testGeneratedScreenshotLibrariesCannotEnterARelease(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ['UITests/Fixtures/Library', 'Cassini.app/Contents/Resources/Fixtures/Library']:
                path = root/relative
                release.reject_generated_library(path)
                path.mkdir(parents=True)
                with self.assertRaises(ValueError): release.reject_generated_library(path)
                path.rmdir()
                path.symlink_to(root/'missing')
                with self.assertRaises(ValueError): release.reject_generated_library(path)

    def testHTTPSOnlyWithoutEmbeddedCredentialsOrPlaceholders(self):
        for url in ['http://example.org/appcast.xml','https://a:b@example.org/x','https://example.org/x#fragment',
                    'https://example.org/PLACEHOLDER/x','https://updates.invalid/x','file:///tmp/x']:
            with self.assertRaises(ValueError):release.https_url(url)
        self.assertEqual(release.https_url('https://example.org/cassini/appcast.xml'),'https://example.org/cassini/appcast.xml')
    def testNotaryTimeoutRetainsSubmissionIdWithoutReupload(self):
        import subprocess, json
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'notary.json'
            with patch.object(release,'run',side_effect=[b'{"id":"known-submission","status":"In Progress"}',subprocess.TimeoutExpired('notarytool',2800)]) as tool:
                with self.assertRaises(subprocess.TimeoutExpired):release.submit_and_wait(Path('app.zip'),[],report)
            self.assertEqual(json.loads(report.read_text())['id'],'known-submission')
            self.assertEqual(tool.call_args_list[0].args[0][2],'submit')
            self.assertEqual(tool.call_args_list[1].args[0][2:4],['wait','known-submission'])

    def testAppcastUsesActualFileSizeEscapesAndBindsBuild(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive=Path(temporary)/'Cassini.dmg';archive.write_bytes(b'12345')
            data=release.appcast(archive,'A'*86+'==','0.1.2',42,'https://example.org/Cassini.dmg?a=1&b=2',datetime(2026,10,30,tzinfo=timezone.utc))
            root=ET.fromstring(data);item=root.find('channel/item');enclosure=item.find('enclosure')
            self.assertEqual(item.find('{'+release.SPARKLE+'}version').text,'42')
            self.assertEqual(enclosure.attrib['length'],'5')
            self.assertEqual(enclosure.attrib['url'],'https://example.org/Cassini.dmg?a=1&b=2')
            self.assertEqual(enclosure.attrib['{'+release.SPARKLE+'}edSignature'],'A'*86+'==')
            self.assertEqual(item.find('{'+release.SPARKLE+'}minimumSystemVersion').text,'15.0')
    def testMalformedSignatureRejected(self):
        with self.assertRaises(ValueError):release.appcast(Path('/nonexistent'),'bad','1.0',1,'https://example.org/x')
    def testSecretsRejectWorldReadableAndSymlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'private';path.write_text('not an actual key');path.chmod(0o644)
            with self.assertRaises(ValueError):release.private_file(path)
            path.chmod(0o600);self.assertEqual(release.private_file(path),path)
            link=path.parent/'link';link.symlink_to(path)
            with self.assertRaises(ValueError):release.private_file(link)
    def testRFC8032SeedMustMatchEmbeddedPublicKey(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            seed=Path(temporary)/'seed';public=Path(temporary)/'public'
            seed.write_text(base64.b64encode(bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')).decode());seed.chmod(0o600)
            public.write_text(base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode())
            command=['xcrun','swift',str(ROOT/'scripts/check-update-key.swift'),str(seed),str(public)]
            self.assertEqual(subprocess.run(command,capture_output=True).returncode,0)
            public.write_text(base64.b64encode(bytes(32)).decode())
            self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)

    def testMalformedSeedRejectedBeforeUpstreamCanEchoIt(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'key';path.write_text(base64.b64encode(b'short').decode());path.chmod(0o600)
            with self.assertRaises(ValueError):release.verify_update_key(path)
    def testToolFailureDoesNotRevealOutputOrArguments(self):
        import subprocess
        from unittest.mock import patch
        with patch.object(release.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'secret-output',b'secret-error')):
            with self.assertRaises(RuntimeError) as caught:release.run(['security','unlock-keychain','-p','secret-argument'])
        self.assertNotIn('secret',str(caught.exception))
    def testRealUpstreamEd25519VerificationAndTamperRejection(self):
        import subprocess
        tools=ROOT/'.build/Sparkle/distribution/bin/sign_update'
        if not tools.exists():self.skipTest('Fetch pinned Sparkle tools before this cryptographic check')
        # Test key only: never access the retained production update key.
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);seed=folder/'seed';seed.write_text(base64.b64encode(bytes(range(32))).decode());seed.chmod(0o600)
            data=folder/'archive';data.write_bytes(b'actual bytes to bind')
            signed=subprocess.run([str(tools),'--ed-key-file',str(seed),'-p',str(data)],check=True,capture_output=True,text=True).stdout.strip()
            command=[str(tools),'--verify','--ed-key-file',str(seed),str(data),signed]
            self.assertEqual(subprocess.run(command,capture_output=True).returncode,0)
            feed=folder/'appcast.xml'
            feed.write_bytes(release.appcast(data,signed,'1.0',2,'https://example.org/Cassini.dmg'))
            subprocess.run([str(tools),'--ed-key-file',str(seed),str(feed)],check=True,capture_output=True)
            verify_feed=[str(tools),'--verify','--ed-key-file',str(seed),str(feed)]
            self.assertEqual(subprocess.run(verify_feed,capture_output=True).returncode,0)
            feed.write_bytes(feed.read_bytes().replace(b'Cassini for Mac',b'Tampered title'))
            self.assertNotEqual(subprocess.run(verify_feed,capture_output=True).returncode,0)
            data.write_bytes(b'tampered bytes');self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)

if __name__ == '__main__':unittest.main()
