#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""publish-release.py against a fake rclone: order, prefix fence, dry run and stops. No network."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publish_release', ROOT/'scripts/publish-release.py')
publish = importlib.util.module_from_spec(spec); spec.loader.exec_module(publish)
SITE = 'https://cassini.talk/download/mac'


class FakeRunner:
    def __init__(self, fail_on=None):
        self.calls = []; self.fail_on = fail_on
    def __call__(self, command, **kwargs):
        self.calls.append(command)
        failed = self.fail_on is not None and self.fail_on in command
        return subprocess.CompletedProcess(command, 1 if failed else 0, '', '')


def release_dir(root, base=SITE, version='0.1.2'):
    output = root/'release'; (output/'notes').mkdir(parents=True)
    files = {'Cassini-talk-'+version+'.dmg': b'dmg', 'Cassini-talk.dmg': b'dmg', 'appcast.xml': b'<rss/>', 'notes/'+version+'.html': b'<p/>'}
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
    (output/'release.json').write_text(json.dumps(dict(version=version, baseURL=base, notarized=True, bytes=3, sha256=sums['Cassini-talk.dmg'])))
    return output, sums


class PublishTests(unittest.TestCase):
    def testDryRunCopiesIntoTheMacPrefixInOrderAndChangesNothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary)); runner = FakeRunner()
            publish.publish(output, runner=runner, log=lambda _: None, env=Path('/nonexistent/r2.env'))
            rclone = [call[4:] for call in runner.calls]
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
            publish.publish(output, dry_run=False, runner=lambda c, **k: (order.append(c[-1] if '--immutable' not in c else c[-2]), runner(c))[1],
                            verify=verify, log=lambda _: None)
            self.assertEqual(order[1], 'verify')
            self.assertTrue(order[-1].endswith('/appcast.xml'))
            self.assertFalse(any('--dry-run' in call for call in runner.calls))

    def testAFailedHTTPSCheckStopsBeforeTheLatestCopyAndAppcast(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary)); runner = FakeRunner()
            with self.assertRaises(ValueError):
                publish.publish(output, dry_run=False, runner=runner, log=lambda _: None,
                                verify=lambda _: dict(bytes=3, sha256='0'*64, edSignatureVerified=True))
            self.assertEqual(len(runner.calls), 1)

    def testAnRcloneFailureStopsThePlan(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary))
            runner = FakeRunner(fail_on='cassinitalk:cassini-talk/download/mac/Cassini-talk-0.1.2.dmg')
            with self.assertRaises(RuntimeError):
                publish.publish(output, runner=runner, log=lambda _: None)
            self.assertEqual(len(runner.calls), 1)

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

    def testTheCommandLineRefusesALiveRunWithoutVersionAndQA(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, _ = release_dir(Path(temporary))
            for extra in [['--publish', '0.1.2'], ['--publish', '9.9', '--clean-vm-qa-passed']]:
                result = subprocess.run(['python3', ROOT/'scripts/publish-release.py', output, *extra], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main()
