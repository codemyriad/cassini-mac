#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure files/XML and cryptographic CLI checks; no app/desktop/device execution."""
import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT/'scripts/release.py')
release = importlib.util.module_from_spec(spec);spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def testHTTPSOnlyWithoutEmbeddedCredentialsOrPlaceholders(self):
        for url in ['http://example.org/appcast.xml','https://a:b@example.org/x','https://example.org/x#fragment',
                    'https://example.org/PLACEHOLDER/x','https://updates.invalid/x','file:///tmp/x']:
            with self.assertRaises(ValueError):release.https_url(url)
        self.assertEqual(release.https_url('https://example.org/cassini/appcast.xml'),'https://example.org/cassini/appcast.xml')
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
