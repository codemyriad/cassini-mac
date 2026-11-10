#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fast Xcode-selection checks using private fake bundles and a fake version command."""
from pathlib import Path
import hashlib,os,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parent.parent
class Selection(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.apps=self.root/'Applications with spaces';self.apps.mkdir()
  self.bin=self.root/'bin';self.bin.mkdir()
  tool=self.bin/'xcodebuild'
  tool.write_text('#!/bin/bash\nset -eu\n[[ "$1" = -version ]]\ncase "$DEVELOPER_DIR" in\n*Xcode_16.4.app*) printf "Xcode 16.4\\nBuild version 16F6\\n";;\n*Xcode-27.0.0.app*) printf "Xcode 27.0\\nBuild version 27A266a\\n";;\n*) exit 73;;\nesac\n');tool.chmod(0o755)
  sdk=self.bin/'xcrun'
  sdk.write_text('#!/bin/bash\nset -eu\n[[ "$*" = "--sdk macosx --show-sdk-path" ]]\nprintf "%s/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\\n" "$DEVELOPER_DIR"\n');sdk.chmod(0o755)
  self.env=dict(os.environ,CI_XCODE_APPLICATIONS=str(self.apps),GITHUB_WORKSPACE=str(self.root/'checkout one'),GITHUB_ENV=str(self.root/'env'),GITHUB_OUTPUT=str(self.root/'outputs'),PATH=str(self.bin)+':/usr/bin:/bin')
 def install(self,bundle): (self.apps/bundle/'Contents/Developer').mkdir(parents=True)
 def run_selector(self): return subprocess.run(['bash',str(ROOT/'scripts/ci-select-xcode.sh')],env=self.env,capture_output=True,text=True)
 def test_hosted_prefers_164_even_if_both_exist(self):
  self.install('Xcode_16.4.app');self.install('Xcode-27.0.0.app')
  result=self.run_selector();self.assertEqual(result.returncode,0,result.stderr)
  selected=str(self.apps/'Xcode_16.4.app/Contents/Developer')
  self.assertEqual((self.root/'env').read_text(),'DEVELOPER_DIR='+selected+'\nSDKROOT='+selected+'/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\n')
  self.assertIn('Xcode 16.4',result.stdout)
 def test_rented_mac_uses_27_and_separates_cache_identity(self):
  self.install('Xcode-27.0.0.app')
  result=self.run_selector();self.assertEqual(result.returncode,0,result.stderr)
  self.assertIn('Xcode-27.0.0.app/Contents/Developer',(self.root/'env').read_text())
  fingerprint=hashlib.sha256(b'Xcode 27.0\nBuild version 27A266a').hexdigest()
  workspace=hashlib.sha256(self.env['GITHUB_WORKSPACE'].encode()).hexdigest()
  self.assertEqual((self.root/'outputs').read_text(),'fingerprint='+fingerprint+'\nworkspace='+workspace+'\n')
  self.assertNotEqual(fingerprint,hashlib.sha256(b'Xcode 16.4\nBuild version 16F6').hexdigest())
 def test_same_xcode_in_different_workspaces_separates_precompiled_header_caches(self):
  self.install('Xcode_16.4.app')
  identities=[]
  for workspace in ['/Users/runner/work/cassini-mac/cassini-mac','/Users/m1/runners/scw-m4-mac-1/_work/cassini-mac/cassini-mac']:
   self.env['GITHUB_WORKSPACE']=workspace
   (self.root/'outputs').unlink(missing_ok=True)
   result=self.run_selector();self.assertEqual(result.returncode,0,result.stderr)
   output=dict(line.split('=',1) for line in (self.root/'outputs').read_text().splitlines())
   self.assertEqual(output['workspace'],hashlib.sha256(workspace.encode()).hexdigest())
   identities.append(output)
  self.assertEqual(identities[0]['fingerprint'],identities[1]['fingerprint'])
  self.assertNotEqual(identities[0]['workspace'],identities[1]['workspace'])
 def test_failed_version_probe_cannot_publish_a_cache_identity(self):
  self.install('Xcode-27.0.0.app')
  (self.bin/'xcodebuild').write_text('#!/bin/bash\nexit 73\n')
  result=self.run_selector();self.assertEqual(result.returncode,73)
  self.assertFalse((self.root/'outputs').exists())
 def test_failed_sdk_probe_cannot_publish_a_cache_identity(self):
  self.install('Xcode_16.4.app')
  (self.bin/'xcrun').write_text('#!/bin/bash\nexit 74\n')
  result=self.run_selector();self.assertEqual(result.returncode,74)
  self.assertFalse((self.root/'outputs').exists())
 def test_missing_or_incomplete_bundle_fails_without_publishing_selection(self):
  (self.apps/'Xcode_16.4.app').mkdir()
  result=self.run_selector();self.assertNotEqual(result.returncode,0)
  self.assertFalse((self.root/'env').exists());self.assertFalse((self.root/'outputs').exists())
if __name__=='__main__': unittest.main()
