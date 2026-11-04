#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""publish-release.py against a fake rclone: order, prefix fence, dry run, stops and the
deployed-release check. No network."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import fcntl
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publish_release', ROOT/'scripts/publish-release.py')
publish = importlib.util.module_from_spec(spec); spec.loader.exec_module(publish)
SITE = 'https://cassini.talk/download/mac'


def feed(version, build):
    return ('<?xml version="1.0" encoding="utf-8"?><!-- sparkle-sign-warning: --><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
            '<channel><item><title>Cassini talk '+version+'</title><sparkle:version>'+str(build)+'</sparkle:version><sparkle:shortVersionString>'+version+
            '</sparkle:shortVersionString><enclosure url="'+SITE+'/Cassini-talk-'+version+'.dmg" length="3"/></item></channel></rss>'
            '<!-- sparkle-signatures:\nedSignature: x\nlength: 1\n-->').encode()


class FakeRunner:
    """rclone stand-in. `deployed` is the appcast bytes in the bucket, or None for none."""
    def __init__(self, fail_on=None, deployed=None, listing=()):
        self.calls = []; self.fail_on = fail_on; self.deployed = deployed; self.listing = list(listing)
    def __call__(self, command, **kwargs):
        self.calls.append(command)
        failed = self.fail_on is not None and self.fail_on in command
        stdout = ''
        if command[4] == 'lsf':
            stdout = ''.join(name+'\n' for name in ['Cassini-talk.dmg', *self.listing]) + ('appcast.xml\n' if self.deployed is not None else '')
        elif command[4] == 'cat':
            stdout = self.deployed if kwargs.get('text') is False else self.deployed.decode()
        return subprocess.CompletedProcess(command, 1 if failed else 0, stdout, '')
    @property
    def copies(self):
        return [call for call in self.calls if call[4] == 'copyto']


def release_dir(root, base=SITE, version='0.1.2', build=12):
    output = root/'release'; (output/'notes').mkdir(parents=True)
    files = {'Cassini-talk-'+version+'.dmg': b'dmg', 'Cassini-talk.dmg': b'dmg', 'appcast.xml': feed(version, build), 'notes/'+version+'.html': b'<p/>'}
    for name, data in files.items():
        (output/name).write_bytes(data)
    sums = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
    (output/'SHA256SUMS').write_text(''.join(d+'  '+n+'\n' for n, d in sums.items()))
    steps = [dict(action='upload', file='Cassini-talk-'+version+'.dmg', url=base+'/Cassini-talk-'+version+'.dmg', overwrite=False),
        dict(action='verifyHTTPS', url=base+'/Cassini-talk-'+version+'.dmg', bytes=3, sha256=sums['Cassini-talk.dmg'], edSignature='sig'),
        dict(action='upload', file='Cassini-talk.dmg', url=base+'/Cassini-talk.dmg', overwrite=True),
        dict(action='upload', file='notes/'+version+'.html', url=base+'/notes/'+version+'.html', overwrite=False),
        dict(action='upload', file='appcast.xml', url=base+'/appcast.xml', overwrite=True)]
    (output/'publication.json').write_text(json.dumps(dict(version=version, baseURL=base, steps=steps)))
    (output/'release.json').write_text(json.dumps(dict(version=version, build=build, baseURL=base, notarized=True, bytes=3, sha256=sums['Cassini-talk.dmg'])))
    return output, sums


class PublishTests(unittest.TestCase):
    def setUp(self):
        # Never touch the real ~/.cassini-release.lock.
        self.lockdir = tempfile.TemporaryDirectory(); self.addCleanup(self.lockdir.cleanup)
        publish.LOCK = Path(self.lockdir.name)/'release.lock'

    def testDryRunCopiesIntoTheMacPrefixInOrderAndChangesNothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary)); runner = FakeRunner()
            publish.publish(output, runner=runner, log=lambda _: None, env=Path('/nonexistent/r2.env'))
            rclone = [call[4:] for call in runner.copies]
            self.assertEqual([args[2] for args in rclone], ['cassinitalk:cassini-talk/download/mac/Cassini-talk-0.1.2.dmg',
                'cassinitalk:cassini-talk/download/mac/Cassini-talk.dmg', 'cassinitalk:cassini-talk/download/mac/notes/0.1.2.html',
                'cassinitalk:cassini-talk/download/mac/appcast.xml'])
            self.assertTrue(all(args[0] == 'copyto' and '--dry-run' in args for args in rclone))
            self.assertIn('--immutable', rclone[0]); self.assertIn('--immutable', rclone[2])
            self.assertNotIn('--immutable', rclone[1]); self.assertNotIn('--immutable', rclone[3])
            # Credentials are sourced inside sh -c from the env file path; no value is on argv.
            for call in runner.calls:
                self.assertEqual(call[:4], ['sh', '-c', 'set -a; . "$0"; set +a; exec rclone "$@"', '/nonexistent/r2.env'])

    def testLiveUploadVerifiesTheDMGOverHTTPSBeforeTheLatestCopyAndAppcast(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, sums = release_dir(Path(temporary)); runner = FakeRunner(); order = []
            def verify(_):
                order.append('verify'); return dict(bytes=3, sha256=sums['Cassini-talk.dmg'], edSignatureVerified=True)
            publish.publish(output, dry_run=False, runner=lambda c, **k: (c[4] == 'copyto' and order.append(c[-1] if '--immutable' not in c else c[-2]), runner(c, **k))[1],
                            verify=verify, log=lambda _: None)
            self.assertEqual(order[1], 'verify')
            self.assertTrue(order[-1].endswith('/appcast.xml'))
            self.assertFalse(any('--dry-run' in call for call in runner.calls))
            self.assertEqual([call[4] for call in runner.calls[:1]], ['lsf'])

    def testAFailedHTTPSCheckStopsBeforeTheLatestCopyAndAppcast(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary)); runner = FakeRunner()
            with self.assertRaises(ValueError):
                publish.publish(output, dry_run=False, runner=runner, log=lambda _: None,
                                verify=lambda _: dict(bytes=3, sha256='0'*64, edSignatureVerified=True))
            self.assertEqual(len(runner.copies), 1)

    def testAnRcloneFailureStopsThePlan(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary))
            runner = FakeRunner(fail_on='cassinitalk:cassini-talk/download/mac/Cassini-talk-0.1.2.dmg')
            with self.assertRaises(RuntimeError):
                publish.publish(output, runner=runner, log=lambda _: None)
            self.assertEqual(len(runner.copies), 1)

    def testOnlyTheMacPrefixIsReachable(self):
        self.assertEqual(publish.bucket_key(SITE+'/appcast.xml'), 'download/mac/appcast.xml')
        for url in ['https://cassini.talk/index.html', 'https://cassini.talk/404.html', 'http://cassini.talk/download/mac/appcast.xml',
                    SITE, SITE+'/', SITE+'/../index.html', SITE+'/notes/../../index.html', SITE+'/a//b', SITE+'x/appcast.xml',
                    'https://cassini.talk.example/download/mac/appcast.xml', SITE+'/appcast.xml?x=1']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                publish.bucket_key(url)
        for arguments in [['sync', 'a', 'cassinitalk:cassini-talk/download/mac/'], ['delete', 'cassinitalk:cassini-talk/download/mac/x'],
                          ['purge', 'cassinitalk:cassini-talk/'], ['copyto', 'a', 'cassinitalk:cassini-talk/index.html']]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                publish.rclone(arguments, runner=FakeRunner())

    def testAReleaseForAnotherBaseOrWithChangedBytesIsRefused(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), base='https://fixture.example/mac')
            with self.assertRaises(ValueError): publish.publish(output, runner=FakeRunner(), log=lambda _: None)
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary)); (output/'appcast.xml').write_bytes(b'<rss>changed</rss>')
            runner = FakeRunner()
            with self.assertRaises(ValueError): publish.publish(output, runner=runner, log=lambda _: None)
            self.assertEqual(runner.calls, [])

    def assertRefusedBeforeAnyUpload(self, output, deployed, reason):
        for dry_run in [True, False]:
            runner = FakeRunner(deployed=deployed)
            with self.subTest(dry_run=dry_run), self.assertRaisesRegex(ValueError, reason):
                publish.publish(output, dry_run=dry_run, runner=runner, log=lambda _: None, verify=lambda _: self.fail('verified'))
            self.assertEqual(runner.copies, [])
            self.assertEqual([call[4] for call in runner.calls], ['lsf', 'cat'])

    def testALowerVersionThanTheDeployedOneIsRefused(self):
        with tempfile.TemporaryDirectory() as temporary:
            # 0.1.1 (13) after 0.1.2 (12): a higher build cannot excuse a lower version.
            output, _ = release_dir(Path(temporary), version='0.1.1', build=13)
            self.assertRefusedBeforeAnyUpload(output, feed('0.1.2', 12), 'lower version')
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), version='0.1.10', build=13)
            # Numeric, not string, comparison: 0.1.10 is newer than 0.1.9.
            runner = FakeRunner(deployed=feed('0.1.9', 12))
            publish.publish(output, runner=runner, log=lambda _: None)
            self.assertEqual(len(runner.copies), 4)

    def testABuildThatIsNotHigherThanTheDeployedOneIsRefused(self):
        # The reviewed case: 0.1.1 (1) after 0.1.0 (9) would replace the feed and Sparkle users never update.
        for version, build in [('0.1.1', 1), ('0.1.1', 9), ('0.1.0', 8)]:
            with self.subTest(version=version, build=build), tempfile.TemporaryDirectory() as temporary:
                output, _ = release_dir(Path(temporary), version=version, build=build)
                self.assertRefusedBeforeAnyUpload(output, feed('0.1.0', 9), 'lower version' if version < '0.1.0' else 'build must be higher')

    def testOnlyAByteIdenticalRetryOfTheDeployedReleaseIsAllowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), version='0.1.0', build=9)
            runner = FakeRunner(deployed=(output/'appcast.xml').read_bytes()); messages = []
            publish.publish(output, runner=runner, log=messages.append)
            self.assertIn('byte-identical', messages[0]); self.assertEqual(len(runner.copies), 4)
            # Same version and build but different feed bytes is not a retry.
            self.assertRefusedBeforeAnyUpload(output, feed('0.1.0', 9).replace(b'Cassini talk', b'Cassini  talk'), 'build must be higher')

    def testANewerReleaseOrTheFirstOneIsAllowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), version='0.1.1', build=10)
            for deployed, expected in [(None, 'first release'), (feed('0.1.0', 9), 'older than 0.1.1 (10)'), (feed('0.1.1', 9), 'older than')]:
                runner = FakeRunner(deployed=deployed); messages = []
                publish.publish(output, runner=runner, log=messages.append)
                self.assertIn(expected, messages[0]); self.assertEqual(len(runner.copies), 4)

    def testAnUnreadableDeployedAppcastStopsBeforeAnyUpload(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary))
            for deployed in [b'<rss/>', b'not xml', feed('0.1.0', 9)[:-40], feed('0.1.0', 9).replace(b'>9<', b'>nine<')]:
                runner = FakeRunner(deployed=deployed)
                with self.subTest(deployed=deployed), self.assertRaises(ValueError):
                    publish.publish(output, runner=runner, log=lambda _: None)
                self.assertEqual(runner.copies, [])

    def testAnRcloneErrorReadingTheBucketIsNeverTakenForAFirstRelease(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), version='0.1.1', build=1)
            for step in ['lsf', 'cat']:
                runner = FakeRunner(fail_on=step, deployed=feed('0.1.0', 9))
                with self.subTest(step=step), self.assertRaises(RuntimeError):
                    publish.publish(output, dry_run=False, runner=runner, log=lambda _: None)
                self.assertEqual(runner.copies, [])

    def testTheUploadedAppcastMustAnnounceTheReleaseItClaims(self):
        with tempfile.TemporaryDirectory() as temporary:
            # release.json says 0.1.1 (10) but the signed feed that would be uploaded says build 1.
            output, _ = release_dir(Path(temporary), version='0.1.1', build=10)
            report = json.loads((output/'release.json').read_text())
            stale = feed('0.1.1', 1); (output/'appcast.xml').write_bytes(stale)
            sums = (output/'SHA256SUMS').read_text().splitlines()
            (output/'SHA256SUMS').write_text(''.join((hashlib.sha256(stale).hexdigest()+'  appcast.xml' if line.endswith('  appcast.xml') else line)+'\n' for line in sums))
            self.assertEqual(report['build'], 10)
            self.assertRefusedBeforeAnyUpload(output, feed('0.1.0', 9), 'does not announce')

    def testANewerVersionedDMGInTheBucketBlocksAnOlderRelease(self):
        # A publish of 0.1.2 stopped after the latest copy, before the appcast: no feed yet,
        # but publishing 0.1.1 now would roll Cassini-talk.dmg back.
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary), version='0.1.1', build=11)
            for deployed in [None, feed('0.1.0', 9)]:
                runner = FakeRunner(deployed=deployed, listing=['Cassini-talk-0.1.2.dmg', 'Cassini-talk-0.1.0.dmg'])
                with self.subTest(deployed=deployed), self.assertRaisesRegex(ValueError, 'newer Cassini-talk-0.1.2.dmg'):
                    publish.publish(output, runner=runner, log=lambda _: None)
                self.assertEqual(runner.copies, [])
            # Retrying the same version, or a newer one, is not blocked by it.
            runner = FakeRunner(deployed=feed('0.1.0', 9), listing=['Cassini-talk-0.1.1.dmg', 'Cassini-talk-0.1.0.dmg'])
            publish.publish(output, runner=runner, log=lambda _: None)
            self.assertEqual(len(runner.copies), 4)

    def testASecondPublisherFailsFastOnTheLock(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, sums = release_dir(Path(temporary)); runner = FakeRunner()
            # Another publisher holds the lock (a separate open file, as a second process would).
            with open(publish.LOCK, 'a') as other:
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(RuntimeError, 'Another publish holds'):
                    publish.publish(output, dry_run=False, runner=runner, log=lambda _: None,
                                    verify=lambda _: dict(bytes=3, sha256=sums['Cassini-talk.dmg'], edSignatureVerified=True))
            self.assertEqual(runner.calls, [])
            # Released: the same publish runs.
            publish.publish(output, dry_run=False, runner=runner, log=lambda _: None,
                            verify=lambda _: dict(bytes=3, sha256=sums['Cassini-talk.dmg'], edSignatureVerified=True))
            self.assertEqual(len(runner.copies), 4)

    def testAFeedChangedDuringThePublishAbortsBeforeTheFeedUpload(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, sums = release_dir(Path(temporary), version='0.1.1', build=10)
            runner = FakeRunner(deployed=feed('0.1.0', 9))
            def verify(_):
                # A concurrent publisher deploys 0.1.2 (11) while this one is between steps.
                runner.deployed = feed('0.1.2', 11)
                return dict(bytes=3, sha256=sums['Cassini-talk.dmg'], edSignatureVerified=True)
            with self.assertRaisesRegex(RuntimeError, 'changed during this publish'):
                publish.publish(output, dry_run=False, runner=runner, log=lambda _: None, verify=verify)
            uploaded = [call[6] for call in runner.copies]
            self.assertFalse(any(key.endswith('/appcast.xml') for key in uploaded), uploaded)
            self.assertEqual([call[4] for call in runner.calls][-2:], ['lsf', 'cat'])

    def testTheCommandLineRefusesALiveRunWithoutVersionAndQA(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary))
            for extra in [['--publish', '0.1.2'], ['--publish', '9.9', '--clean-vm-qa-passed']]:
                result = subprocess.run(['python3', ROOT/'scripts/publish-release.py', output, *extra], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main()
