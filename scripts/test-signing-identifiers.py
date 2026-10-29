#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sign generated fixture code and inspect it; never launch an app or helper."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class SigningIdentifiersTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cassini-signing-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root/'fixture.c'; source.write_text('int main(void) { return 0; }\n')
        self.binary = self.root/'fixture'
        subprocess.run(['clang', str(source), '-o', str(self.binary)], check=True, capture_output=True)
        self.app = self.root/'Fixture.app'
        self.bundles = [('', ''), ('Contents/PlugIns/CassiniQuickLook.appex', '.quicklook'),
            ('Contents/XPCServices/CassiniBrowserSetup.xpc', '.browser-setup'),
            ('Contents/XPCServices/CassiniModelDownloads.xpc', '.models')]
        for relative, suffix in self.bundles:
            bundle = self.app/relative; macos = bundle/'Contents/MacOS'; macos.mkdir(parents=True)
            (macos/'Fixture').write_bytes(self.binary.read_bytes())
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Fixture',
                CFBundleIdentifier='io.codemyriad.cassini'+suffix, CFBundlePackageType='APPL' if not relative else 'XPC!')))
        for name in ['browser-host','control-host','whistle-worker','parakeet-worker']:
            path = self.app/'Contents/MacOS'/('cassini-'+name)
            path.write_bytes(self.binary.read_bytes()); self.sign(path, 'io.codemyriad.cassini.'+name)
        for engine, names in [('Whistle',['libneedle3.dylib','libonnxruntime.1.23.2.dylib']),
                              ('Parakeet',['libsherpa-onnx-c-api.dylib','libonnxruntime.dylib'])]:
            resources = self.app/'Contents/Resources'/engine; resources.mkdir(parents=True)
            frameworks = self.app/'Contents/Frameworks'; frameworks.mkdir(exist_ok=True)
            paths = [self.app/'Contents/MacOS'/('cassini-'+engine.lower()+'-worker')]
            for name in names:
                path = frameworks/name; path.write_bytes(self.binary.read_bytes());self.sign(path,name);paths.append(path)
            if engine == 'Whistle':
                for name in ['silero_vad.onnx','whistle.cact']:
                    path = resources/name;path.write_bytes(b'generated public fixture');paths.append(path)
            (resources/'bundle-sha256.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}))
        for relative, suffix in reversed(self.bundles):
            self.sign(self.app/relative, 'io.codemyriad.cassini'+suffix)
    def sign(self, path, identifier):
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--options','runtime','-i',identifier,str(path)],check=True,capture_output=True)
    def inspect(self, strict=False):
        command=['python3',str(ROOT/'scripts/check-signing-identifiers.py'),str(self.app)]
        if strict:command.append('--require-hardened-runtime')
        return subprocess.run(command,capture_output=True,text=True)
    def testValidFinishedBundle(self):
        result = self.inspect(strict=True);self.assertEqual(result.returncode,0,result.stderr)
    def testWrongHelperSigningIdentifierIsRejected(self):
        self.sign(self.app/'Contents/MacOS/cassini-browser-host','com.example.unrelated')
        result=self.inspect();self.assertNotEqual(result.returncode,0);self.assertIn('com.example.unrelated',result.stderr)
    def testChangedWorkerBytesInvalidateRecordedHash(self):
        worker=self.app/'Contents/MacOS/cassini-whistle-worker'
        with worker.open('ab') as stream:stream.write(b'changed after build')
        result=self.inspect();self.assertNotEqual(result.returncode,0);self.assertIn('signed bytes changed',result.stderr)
    def testAdHocRuntimePolicyAndStrictFlagCheck(self):
        service=self.app/'Contents/XPCServices/CassiniModelDownloads.xpc'
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--options','0',
            '-i','io.codemyriad.cassini.models',str(service)],check=True,capture_output=True)
        result=self.inspect();self.assertEqual(result.returncode,0,result.stderr)
        result=self.inspect(strict=True);self.assertNotEqual(result.returncode,0);self.assertIn('missing hardened runtime',result.stderr)
    def testXcodeProductSigningSettings(self):
        result=subprocess.run(['xcodebuild','-showBuildSettings','-json','-project',str(ROOT/'Cassini.xcodeproj'),'-alltargets'],
            check=True,capture_output=True,text=True,timeout=90)
        expected={'Cassini':'','CassiniQuickLook':'.quicklook','CassiniBrowserSetup':'.browser-setup',
            'CassiniModelDownloads':'.models','CassiniBrowserHost':'.browser-host','CassiniControlHost':'.control-host',
            'CassiniWhistleWorker':'.whistle-worker','CassiniParakeetWorker':'.parakeet-worker','CassiniWindowScreenshots':'.screenshots'}
        found=set()
        for entry in json.loads(result.stdout):
            name=entry['target'];settings=entry['buildSettings']
            if name not in expected:continue
            found.add(name);self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'],'io.codemyriad.cassini'+expected[name])
            self.assertEqual(settings['ENABLE_HARDENED_RUNTIME'],'NO' if name=='CassiniWindowScreenshots' else 'YES',name)
            self.assertEqual(settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'],'YES' if name=='CassiniWindowScreenshots' else 'NO',name)
            self.assertIn('--timestamp',settings['OTHER_CODE_SIGN_FLAGS'],name)
            if name in ['CassiniBrowserHost','CassiniControlHost','CassiniWhistleWorker','CassiniParakeetWorker']:
                self.assertIn('-i '+settings['PRODUCT_BUNDLE_IDENTIFIER'],settings['OTHER_CODE_SIGN_FLAGS'],name)
        self.assertEqual(found,set(expected))
    def testWrongServiceBundleIdentifierIsRejected(self):
        path=self.app/'Contents/XPCServices/CassiniModelDownloads.xpc/Contents/Info.plist'
        info=plistlib.loads(path.read_bytes());info['CFBundleIdentifier']='com.example.unrelated';path.write_bytes(plistlib.dumps(info))
        result=self.inspect();self.assertNotEqual(result.returncode,0);self.assertIn('com.example.unrelated',result.stderr)

if __name__ == '__main__':
    unittest.main()
