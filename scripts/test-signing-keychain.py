#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""setup-signing-keychain.py never prints the keychain password when a command hangs or fails.

Each case runs the script's real command-line entry point in a child interpreter with a
fake `security`/`openssl` runner, so an uncaught exception would reach Python's own
traceback printer exactly as in production. Nothing touches a real keychain.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PASSWORD = 'pw-SENTINEL-' + 'x'*40
CHILD = r'''
import importlib.util, json, subprocess, sys
from pathlib import Path
root, folder, step, mode = sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4]
spec = importlib.util.spec_from_file_location('setup_signing_keychain', root + '/scripts/setup-signing-keychain.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
password = (folder/'cassini-signing-keychain.password').read_text()
def runner(command, **kwargs):
    assert kwargs.get('timeout'), 'every command has a timeout'
    if command[:2] == ['security', step]:
        if mode == 'timeout':
            raise subprocess.TimeoutExpired(command, kwargs['timeout'], output=password.encode(), stderr=password.encode())
        if mode == 'oserror':
            raise PermissionError(13, 'denied ' + password, command[0])
        if mode == 'exit':
            return subprocess.CompletedProcess(command, 51, password.encode(), password.encode())
    if command[0] == 'openssl':
        return subprocess.CompletedProcess(command, 0, b'same public key', b'')
    if command[:2] == ['security', 'find-identity']:
        return subprocess.CompletedProcess(command, 0, b'1) ' + b'A'*40 + b' "Developer ID Application: Codemyriad OU (4LS8W738Y3)"', b'')
    if command[:2] == ['codesign', '-d']:
        return subprocess.CompletedProcess(command, 0, b'', b'flags=0x10000(runtime)\nTeamIdentifier=4LS8W738Y3')
    return subprocess.CompletedProcess(command, 0, b'', b'')
sys.exit(module.cli(folder, runner))
'''


class KeychainSecretTests(unittest.TestCase):
    def run_child(self, step, mode, keychain_exists):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder/'cassini-signing-keychain.password').write_text(PASSWORD)
            if keychain_exists:
                (folder/'cassini-signing.keychain-db').write_bytes(b'')
            return subprocess.run([sys.executable, '-c', CHILD, str(ROOT), str(folder), step, mode], capture_output=True, text=True, timeout=60)

    def testAHungOrFailingPasswordCommandNeverPrintsThePassword(self):
        # create-keychain runs only for a new keychain; unlock and partition setup always run.
        for step, exists in [('create-keychain', False), ('unlock-keychain', True), ('set-key-partition-list', True)]:
            for mode in ['timeout', 'oserror', 'exit']:
                with self.subTest(step=step, mode=mode):
                    result = self.run_child(step, mode, exists)
                    output = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 1, output)
                    self.assertNotIn('SENTINEL', output)
                    self.assertNotIn('Traceback', output)
                    self.assertIn('security ' + step, result.stderr)
                    self.assertIn({'timeout': 'timed out', 'oserror': 'could not run', 'exit': 'exit 51'}[mode], result.stderr)

    def testTheHappyPathStillReportsWithoutThePassword(self):
        result = self.run_child('none', 'none', True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('SENTINEL', result.stdout + result.stderr)
        self.assertTrue(json.loads(result.stdout)['probe_signed_and_verified'])


if __name__ == '__main__':
    unittest.main()
